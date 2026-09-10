//
//  RaptorHistoryReasoningStamp.swift
//  OsaurusCore
//
//  Installed Raptor v0.5 bundles get `reasoning.history_reasoning: "omit"`
//  stamped into their jang_config.json so `DeclaredReasoningEffort.historyReasoningOmitted`
//  applies to existing installs, not only to bundles downloaded after the key
//  was added upstream. Raptor v0.5 (Ling 3.0 based) copies its own prior
//  tool-cycle `<think>` verbatim once one identical turn exists (engine ladder
//  4/5, 5/5, 4/5 re-issue with history thinking kept vs 0/5, 1/5, 0/5 with it
//  stripped). The rewrite is textual (one inserted line, formatting and key
//  order preserved), verified by re-parsing, idempotent, and scoped to the
//  validated legacy bundles only: ids under `OsaurusAI/Raptor-v0.5` whose
//  config.json names the Ling `bailing_hybrid` model type. Raptor 0.6
//  (Nanbeige) and any other family are never eligible.
//

import Foundation

enum RaptorHistoryReasoningStamp {

    /// Name gate: the validated legacy family only — `OsaurusAI/Raptor-v0.5`
    /// and its dash-suffixed variants (`Raptor-v0.5-8B-A1B-JANG_6M`, `…-rtn`).
    /// Case-insensitive on the id. The bare `OsaurusAI/Raptor` repo, any
    /// `Raptor-v0.6-…` (Nanbeige) bundle, a repo merely starting with
    /// "Raptor" (`Raptorial-…`) and other orgs do not qualify. The bundle's
    /// architecture is checked separately (`isLingBased`) before any file is
    /// written.
    static func appliesTo(modelId: String) -> Bool {
        let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id == "osaurusai/raptor-v0.5" || id.hasPrefix("osaurusai/raptor-v0.5-")
    }

    /// The model type the migration was validated on (Ling 3.0, KDA hybrid).
    static let lingModelType = "bailing_hybrid"

    /// Architecture gate: the bundle's config.json must name the Ling model
    /// type. A missing, unreadable, oversized or different config leaves the
    /// bundle untouched — the migration never guesses from the name alone.
    static func isLingBased(directory: URL) -> Bool {
        guard let text = readBounded(directory.appendingPathComponent("config.json")),
            let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let modelType = root["model_type"] as? String
        else { return false }
        return modelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lingModelType
    }

    /// Upper bound for a config we are willing to read on the load path; real
    /// stamps are a few KB.
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
    /// (`AgentReasoningPolicy`). Raptor v0.5 declares its default only in
    /// jang_config (`reasoning.default: "on"`), so every agent request on a
    /// fresh install ran thinking-off against the bundle's contract.
    ///
    /// Inserts ONLY the missing `enable_thinking` leaf, formatting preserved,
    /// re-parsed and byte-compared before writing, idempotent:
    /// - no `default_chat_template_kwargs` → the object is added with the leaf;
    /// - an existing kwargs object without the leaf → the leaf is added and
    ///   every sibling kwarg is kept;
    /// - an existing `enable_thinking` (true OR false) → untouched (nil);
    /// - a non-object value under the key → untouched (nil).
    /// Whether ON is the right value is the caller's decision
    /// (`stampGenerationConfig(in:jangConfigText:)` reads the bundle's own
    /// declared default); this function only knows how to insert.
    static func stampedGenerationConfig(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let existing = root["default_chat_template_kwargs"] {
            guard let kwargs = existing as? [String: Any], kwargs["enable_thinking"] == nil else { return nil }
            // Insert the leaf into the existing object: try each textual
            // occurrence of the key and keep the first whose result re-parses
            // with the leaf on the ROOT kwargs object and everything else
            // byte-for-byte equal.
            var searchFrom = text.startIndex
            while let open = text.range(
                of: #""default_chat_template_kwargs"\s*:\s*\{"#, options: .regularExpression,
                range: searchFrom..<text.endIndex)
            {
                searchFrom = open.upperBound
                let lineStart =
                    text[..<open.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                let indent = String(text[lineStart..<open.lowerBound].prefix { $0 == " " || $0 == "\t" })
                let objectIsEmpty = text[open.upperBound...].first(where: { !$0.isWhitespace }) == "}"
                let insertion = "\n\(indent)  \"enable_thinking\": true" + (objectIsEmpty ? "" : ",")
                var out = text
                out.insert(contentsOf: insertion, at: open.upperBound)
                if verifiedLeafInsertion(out, against: root, createdObject: false) { return out }
            }
            return nil
        }

        guard let open = text.firstIndex(of: "{") else { return nil }
        let afterOpen = text.index(after: open)
        let rest = text[afterOpen...]
        let objectIsEmpty = rest.first(where: { !$0.isWhitespace }) == "}"
        let indent = text[afterOpen...].prefix { $0 == "\n" || $0 == " " || $0 == "\t" }.split(separator: "\n").last.map(String.init) ?? "  "
        let insertion = "\n\(indent)\"default_chat_template_kwargs\": { \"enable_thinking\": true }" + (objectIsEmpty ? "" : ",")
        var out = text
        out.insert(contentsOf: insertion, at: afterOpen)
        return verifiedLeafInsertion(out, against: root, createdObject: true) ? out : nil
    }

    /// True when `out` re-parses with `default_chat_template_kwargs.enable_thinking == true`
    /// and, with that leaf removed (and the object removed when this call
    /// created it), equals `root` value-for-value.
    private static func verifiedLeafInsertion(_ out: String, against root: [String: Any], createdObject: Bool) -> Bool {
        guard let outData = out.data(using: .utf8),
            var outRoot = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
            var outKwargs = outRoot["default_chat_template_kwargs"] as? [String: Any],
            outKwargs["enable_thinking"] as? Bool == true
        else { return false }
        outKwargs["enable_thinking"] = nil
        outRoot["default_chat_template_kwargs"] = createdObject ? nil : outKwargs
        return NSDictionary(dictionary: outRoot).isEqual(to: root)
    }

    /// Whether a generation_config text already declares
    /// `default_chat_template_kwargs.enable_thinking` (either value).
    static func declaresThinkingDefault(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kwargs = root["default_chat_template_kwargs"] as? [String: Any]
        else { return false }
        return kwargs["enable_thinking"] is Bool
    }

    private static let lock = NSLock()
    /// Per-process memo, one entry per FILE (`<key>|jang`, `<key>|generation`),
    /// set only once that file is known to be correct — already carrying the
    /// key, stamped now, or (generation companion only) not applicable by the
    /// bundle's own contract. A missing, unreadable, oversized or unwritable
    /// file is never memoised, so a later load gets another cheap try.
    nonisolated(unsafe) private static var settledThisProcess: Set<String> = []  // guarded by `lock`

    /// Called on the model LOAD path and at declaration resolve, for this
    /// bundle only: small bounded file reads the first time an eligible Raptor
    /// bundle is seen in this process, nothing for any other model id. Never
    /// throws and never blocks the load: an unreadable or unwritable file
    /// (read-only volume) is logged and the load proceeds exactly as before.
    /// Returns true when jang_config.json was rewritten.
    @discardableResult
    static func stampIfNeeded(modelId: String, directory: URL?) -> Bool {
        guard appliesTo(modelId: modelId), let directory else { return false }
        // Memo per (id, resolved directory): the same id relocated or
        // replaced at another path is a different file and gets its own
        // check.
        let key = modelId.lowercased() + "|" + directory.standardizedFileURL.resolvingSymlinksInPath().path
        let jangKey = key + "|jang"
        let generationKey = key + "|generation"
        lock.lock()
        let jangSettled = settledThisProcess.contains(jangKey)
        let generationSettled = settledThisProcess.contains(generationKey)
        lock.unlock()
        if jangSettled && generationSettled { return false }

        guard isLingBased(directory: directory) else {
            print("[Osaurus][RaptorStamp] \(modelId) at \(directory.path): config.json does not name model_type \(lingModelType) — not a validated Ling-based Raptor bundle, left unchanged")
            return false
        }

        let url = directory.appendingPathComponent("jang_config.json")
        guard let text = readBounded(url) else {
            print("[Osaurus][RaptorStamp] jang_config.json missing, unreadable or oversized at \(url.path) — load proceeds unchanged")
            return false
        }

        var jangText = text
        var rewroteJang = false
        if !jangSettled {
            if let rewritten = stamped(text) {
                do {
                    try rewritten.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    print("[Osaurus][RaptorStamp] could not stamp \(url.path): \(error.localizedDescription)")
                    return false
                }
                jangText = rewritten
                rewroteJang = true
                markSettled(jangKey)
                print("[Osaurus][RaptorStamp] history_reasoning=omit stamped into \(url.path)")
                DeclaredReasoningEffort.invalidate()
            } else if carriesKey(text) {
                markSettled(jangKey)
            } else {
                print("[Osaurus][RaptorStamp] jang_config.json at \(url.path) has no root reasoning block to stamp — left unchanged")
                return false
            }
        }

        // The companion follows the history stamp: only a bundle whose
        // jang_config carries the key (already, or as of now) gets its
        // declared default mirrored into generation_config.
        if !generationSettled, carriesKey(jangText) {
            switch stampGenerationConfig(in: directory, jangConfigText: jangText) {
            case .written, .alreadyDeclared, .notApplicable:
                markSettled(generationKey)
            case .retryable:
                break
            }
        }
        return rewroteJang
    }

    enum CompanionOutcome: Equatable {
        /// `enable_thinking: true` was inserted and written.
        case written
        /// generation_config already declares `enable_thinking` (either value).
        case alreadyDeclared
        /// The bundle does not declare thinking ON in jang_config, so no
        /// default is synthesised — explicit OFF and absent defaults are kept.
        case notApplicable
        /// Missing, unreadable, oversized, unparseable or unwritable file;
        /// logged, tried again on a later load.
        case retryable
    }

    /// Companion stamp on generation_config.json (see `stampedGenerationConfig`).
    /// The value written is the bundle's OWN declared serving default read
    /// from jang_config (`reasoning.default: "on"`, the block
    /// `LocalReasoningCapability` already honours); a bundle declaring OFF or
    /// nothing is left exactly as it is. Never throws.
    static func stampGenerationConfig(in directory: URL, jangConfigText: String) -> CompanionOutcome {
        guard let jangData = jangConfigText.data(using: .utf8),
            LocalReasoningCapability.jangConfigDefaultThinkingOn(data: jangData) == true
        else {
            print("[Osaurus][RaptorStamp] jang_config.json in \(directory.path) does not declare reasoning default on — generation_config.json left unchanged")
            return .notApplicable
        }
        let url = directory.appendingPathComponent("generation_config.json")
        guard let text = readBounded(url) else {
            print("[Osaurus][RaptorStamp] generation_config.json missing, unreadable or oversized at \(url.path) — left unchanged, retried on a later load")
            return .retryable
        }
        guard let rewritten = stampedGenerationConfig(text) else {
            if declaresThinkingDefault(text) { return .alreadyDeclared }
            print("[Osaurus][RaptorStamp] generation_config.json at \(url.path) has no usable insertion point — left unchanged, retried on a later load")
            return .retryable
        }
        do {
            try rewritten.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[Osaurus][RaptorStamp] could not stamp \(url.path): \(error.localizedDescription)")
            return .retryable
        }
        print("[Osaurus][RaptorStamp] default_chat_template_kwargs.enable_thinking=true stamped into \(url.path)")
        LocalReasoningCapability.invalidate()
        return .written
    }

    /// One bounded read; nil for a missing, unreadable, oversized or non-UTF-8 file.
    private static func readBounded(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber, size.intValue <= maxConfigBytes,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    private static func markSettled(_ key: String) {
        lock.lock(); settledThisProcess.insert(key); lock.unlock()
    }

    private static func carriesKey(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (root["reasoning"] as? [String: Any])?["history_reasoning"] != nil
    }

    /// Test hook: forget the per-process memo.
    static func resetForTests() {
        lock.lock(); settledThisProcess.removeAll(); lock.unlock()
    }
}
