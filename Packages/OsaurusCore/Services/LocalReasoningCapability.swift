//
//  LocalReasoningCapability.swift
//  osaurus
//
//  Inspects a locally-installed model's chat template to determine whether
//  it supports thinking/reasoning — without hardcoding per-family heuristics.
//  Drives both the UI reasoning toggle and the streaming prepend-think
//  middleware so new reasoning model families (JANG, MiniMax, Mistral-Small-4,
//  etc.) are picked up automatically as long as they ship a chat template.
//

import Foundation

enum LocalReasoningCapability {
    struct Capability: Sendable {
        /// Template references `<think>` or `</think>` tags.
        let supportsThinking: Bool
        /// Template reads an `enable_thinking` kwarg — i.e. thinking is toggleable.
        let hasEnableThinkingKwarg: Bool
        /// Template itself injects a literal `<think>` opener into the assistant prompt
        /// tail, which means the model's generated stream will only contain the closing
        /// `</think>` and needs a middleware prepend for the UI tag parser to work.
        let templateInjectsThinkTag: Bool

        static let none = Capability(
            supportsThinking: false,
            hasEnableThinkingKwarg: false,
            templateInjectsThinkTag: false
        )
    }

    private static nonisolated let lock = NSLock()
    private static nonisolated(unsafe) var cache: [String: Capability] = [:]

    static func capability(forModelId modelId: String) -> Capability {
        let key = modelId.lowercased()
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let detected = detect(modelId: modelId)

        lock.lock()
        cache[key] = detected
        lock.unlock()
        return detected
    }

    /// Call when models are added/removed so the next lookup re-reads templates.
    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - Detection

    private static func detect(modelId: String) -> Capability {
        guard let dir = localDirectory(forModelId: modelId),
            let template = readChatTemplate(at: dir)
        else {
            return .none
        }
        return analyze(template: template)
    }

    /// Pure, testable template analysis.
    static func analyze(template: String) -> Capability {
        let lower = template.lowercased()
        let hasOpen = lower.contains("<think>")
        let hasClose = lower.contains("</think>")
        let hasKwarg = lower.contains("enable_thinking")
        let injects =
            template.range(
                of: #"\{\{-?\s*['\"]<think>"#,
                options: .regularExpression
            ) != nil
        return Capability(
            supportsThinking: hasOpen || hasClose,
            hasEnableThinkingKwarg: hasKwarg,
            templateInjectsThinkTag: injects
        )
    }

    private static func localDirectory(forModelId modelId: String) -> URL? {
        // Delegate to the single source of truth: `findInstalledModel` already
        // accepts both the short repo name (picker/display form) and the full
        // `ORG/REPO` id, case-insensitive. Re-implementing the match here was
        // silently returning nil whenever the caller passed a form neither of
        // our candidate heuristics covered.
        guard let found = ModelManager.findInstalledModel(named: modelId) else {
            return nil
        }
        let parts = found.id.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
        return parts.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private static func readChatTemplate(at dir: URL) -> String? {
        let fm = FileManager.default
        let jinja = dir.appendingPathComponent("chat_template.jinja")
        if fm.fileExists(atPath: jinja.path),
            let s = try? String(contentsOf: jinja, encoding: .utf8)
        {
            return s
        }
        let tokenizerCfg = dir.appendingPathComponent("tokenizer_config.json")
        if fm.fileExists(atPath: tokenizerCfg.path),
            let data = try? Data(contentsOf: tokenizerCfg),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let tmpl = obj["chat_template"] as? String { return tmpl }
            // HF sometimes ships an array form: [{"name": "default", "template": "..."}]
            if let arr = obj["chat_template"] as? [[String: Any]],
                let first = arr.first,
                let tmpl = first["template"] as? String
            {
                return tmpl
            }
        }
        return nil
    }
}
