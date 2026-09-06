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

    /// The Raptor family: the `OsaurusAI/Raptor` repo and its dash-suffixed
    /// variants (`OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M`, future `Raptor-…`).
    /// Case-insensitive on the id; a repo merely STARTING with "Raptor"
    /// (`OsaurusAI/Raptorial-…`) is not Raptor, and no other org qualifies.
    static func appliesTo(modelId: String) -> Bool {
        let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id == "osaurusai/raptor" || id.hasPrefix("osaurusai/raptor-")
    }

    /// Upper bound for a jang_config we are willing to read on the load
    /// path; real stamps are a few KB.
    static let maxConfigBytes = 1 << 20

    /// The rewritten jang_config text, or nil when nothing should change: the
    /// key is already present, there is no top-level `reasoning` object, or
    /// the result would not parse back with the key in place.
    static func stamped(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let reasoning = root["reasoning"] as? [String: Any],
            reasoning["history_reasoning"] == nil
        else { return nil }

        // A nested `"reasoning": {` (legacy `chat.reasoning`) can precede the
        // top-level one in the text: try each textual occurrence and keep the
        // first whose result re-parses with the key on the ROOT reasoning
        // object and every other value byte-for-byte equal.
        var searchFrom = text.startIndex
        while let open = text.range(of: #""reasoning"\s*:\s*\{"#, options: .regularExpression, range: searchFrom..<text.endIndex) {
            searchFrom = open.upperBound
            let lineStart =
                text[..<open.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let indent = String(text[lineStart..<open.lowerBound].prefix { $0 == " " || $0 == "\t" })
            let blockIsEmpty = text[open.upperBound...].first(where: { !$0.isWhitespace }) == "}"
            let insertion = "\n\(indent)  \"history_reasoning\": \"omit\"" + (blockIsEmpty ? "" : ",")
            var out = text
            out.insert(contentsOf: insertion, at: open.upperBound)
            guard let outData = out.data(using: .utf8),
                let outRoot = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
                var outReasoning = outRoot["reasoning"] as? [String: Any],
                outReasoning["history_reasoning"] as? String == "omit"
            else { continue }
            outReasoning["history_reasoning"] = nil
            var strippedRoot = outRoot
            strippedRoot["reasoning"] = outReasoning
            guard NSDictionary(dictionary: strippedRoot).isEqual(to: root) else { continue }
            return out
        }
        return nil
    }

    /// generation_config.json companion: the app treats
    /// `default_chat_template_kwargs.enable_thinking` as the publisher's
    /// declared serving default (the HF-honoured key) and, for agent/tool
    /// requests, forces thinking OFF when a bundle declares none
    /// (`AgentReasoningPolicy`). Raptor declares its default only in
    /// jang_config (`reasoning.default: "on"`), so every agent request on a
    /// fresh install ran thinking-off against the bundle's contract. Insert
    /// the declaration (top-level key, formatting preserved, re-parsed and
    /// byte-compared before writing, idempotent).
    static func stampedGenerationConfig(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["default_chat_template_kwargs"] == nil,
            let open = text.firstIndex(of: "{")
        else { return nil }
        let afterOpen = text.index(after: open)
        let rest = text[afterOpen...]
        let objectIsEmpty = rest.first(where: { !$0.isWhitespace }) == "}"
        let indent = text[afterOpen...].prefix { $0 == "\n" || $0 == " " || $0 == "\t" }.split(separator: "\n").last.map(String.init) ?? "  "
        let insertion = "\n\(indent)\"default_chat_template_kwargs\": { \"enable_thinking\": true }" + (objectIsEmpty ? "" : ",")
        var out = text
        out.insert(contentsOf: insertion, at: afterOpen)
        guard let outData = out.data(using: .utf8),
            var outRoot = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
            (outRoot["default_chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true
        else { return nil }
        outRoot["default_chat_template_kwargs"] = nil
        guard NSDictionary(dictionary: outRoot).isEqual(to: root) else { return nil }
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
        // Memo per (id, resolved directory): the same id relocated or
        // replaced at another path is a different file and gets its own
        // check.
        let key = modelId.lowercased() + "|" + directory.standardizedFileURL.resolvingSymlinksInPath().path
        lock.lock()
        let alreadyChecked = checkedThisProcess.contains(key)
        lock.unlock()
        if alreadyChecked { return false }

        // The memo is set only once the file is known to carry the key
        // (already stamped, or stamped now). A missing/unreadable/unwritable
        // file is NOT memoised, so a later load (volume mounted, permissions
        // fixed) gets another cheap try.
        let url = directory.appendingPathComponent("jang_config.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber, size.intValue <= maxConfigBytes,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            print("[Osaurus][RaptorStamp] jang_config.json missing, unreadable or oversized at \(url.path) — load proceeds unchanged")
            return false
        }
        guard let rewritten = stamped(text) else {
            if Self.carriesKey(text) {
                markChecked(key)
                stampGenerationConfigIfNeeded(in: directory)
            }
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
        stampGenerationConfigIfNeeded(in: directory)
        return true
    }

    /// Companion stamp on generation_config.json (see `stampedGenerationConfig`).
    /// Never throws; a missing/unreadable/unwritable file is logged and skipped.
    @discardableResult
    static func stampGenerationConfigIfNeeded(in directory: URL) -> Bool {
        let url = directory.appendingPathComponent("generation_config.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber, size.intValue <= maxConfigBytes,
            let text = try? String(contentsOf: url, encoding: .utf8),
            let rewritten = stampedGenerationConfig(text)
        else { return false }
        do {
            try rewritten.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[Osaurus][RaptorStamp] could not stamp \(url.path): \(error.localizedDescription)")
            return false
        }
        print("[Osaurus][RaptorStamp] default_chat_template_kwargs.enable_thinking=true stamped into \(url.path)")
        LocalReasoningCapability.invalidate()
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
