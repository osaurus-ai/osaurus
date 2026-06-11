//
//  LocalReasoningCapability.swift
//  osaurus
//
//  Inspects a locally-installed model's chat template to determine whether
//  it supports thinking/reasoning — without hardcoding per-family heuristics.
//  Drives the UI reasoning toggle and metadata reporting so new reasoning
//  model families (JANG, MiniMax, Mistral-Small-4, etc.) are picked up
//  automatically as long as they ship a chat template.
//
//  JANG bundles that omit a chat template entirely — DSV4-Flash is the
//  canonical case, it ships `encoding/encoding_dsv4.py` instead of a Jinja
//  template — are detected via a `jang_config.json > chat > reasoning`
//  fallback so their `.reasoning` events don't get coerced to content by
//  the #934 mitigation in `ModelRuntime.streamWithTools`.
//

import Foundation
import Darwin

enum LocalReasoningCapability {
    struct Capability: Sendable {
        /// Template references `<think>` or `</think>` tags.
        let supportsThinking: Bool
        /// Template reads an `enable_thinking` kwarg.
        let hasEnableThinkingKwarg: Bool
        /// Template itself injects a literal `<think>` opener into the assistant prompt
        /// tail. This is reported as metadata only; runtime code must not synthesize
        /// or prepend thinking tags to repair model output.
        let templateInjectsThinkTag: Bool
        /// True when the template both exposes a toggle kwarg and uses
        /// reasoning markers the runtime recognizes.
        var isToggleableThinking: Bool { supportsThinking && hasEnableThinkingKwarg }

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
        guard let dir = localDirectory(forModelId: modelId) else {
            return .none
        }
        if let template = readChatTemplate(at: dir) {
            return analyze(template: template)
        }
        // Fallback for JANG bundles that ship no chat template (DSV4-Flash
        // ships `encoding/encoding_dsv4.py` instead; the JANG converter
        // stamps `has_tokenizer_chat_template: false` plus an authoritative
        // `chat.reasoning.supported` flag into `jang_config.json`). Without
        // this fallback, `detect()` returned `.none` for DSV4 → `supportsThinking
        // = false` → PR #934's `streamWithTools` coercion merged the model's
        // `.reasoning` deltas into content, wiping out the thinking split.
        if let cap = readJangConfigReasoning(at: dir) {
            return cap
        }
        return .none
    }

    /// Pure, testable template analysis.
    static func analyze(template: String) -> Capability {
        let lower = template.lowercased()
        // Detect two distinct thinking-template conventions:
        //
        // 1. `<think>` / `</think>` — envelope tag pair used by Qwen 3,
        //    Qwen 3.5, DeepSeek-R1, GLM-4.x, MiniMax, Nemotron, etc.
        //    Reasoning content is wrapped BETWEEN the tags; vmlx's
        //    `think_xml` parser peels them off into `.reasoning` events.
        //
        // 2. `<|think|>` — a MODE MARKER (not an envelope) used only by
        //    Gemma-4. Its presence in the template's `enable_thinking`
        //    branch signals "thinking mode is active" — the model then
        //    emits actual CoT content wrapped in
        //    `<|channel>thought\n…<channel|>` envelopes, which vmlx's
        //    `harmony` parser catches. `<|think|>` has no closing pipe
        //    form; checking for it here is purely a capability flag
        //    ("this template supports thinking") to drive the UI toggle
        //    and `AutoThinkingProfile` matching, NOT a parser hint.
        //
        // Before this case existed, `supportsThinking` was `false` for
        // Gemma-4 because `<think>` never matched and
        // `hasEnableThinkingKwarg: true` alone didn't flip the flag.
        let hasOpen = lower.contains("<think>") || lower.contains("<|think|>")
        let hasClose = lower.contains("</think>")
        let hasKwarg = lower.contains("enable_thinking")
        let injects =
            template.range(
                of: #"\{\{-?\s*['\"]<\|?think\|?>"#,
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
        guard let found = ModelManager.findInstalledMLXModel(named: modelId) else {
            return nil
        }
        return found.localDirectory
    }

    /// Read `jang_config.json > chat > reasoning` and surface it as a
    /// `Capability`. Returns nil when the file is missing, malformed, or
    /// doesn't carry the `chat.reasoning` sub-object — the caller should
    /// then return `.none`. Exposed (`static`, not `private`) so unit tests
    /// can exercise fixtures without writing to disk.
    ///
    /// Schema this recognises (a subset of the DSV4-Flash converter's
    /// output; newer JANG bundles are free to add more fields and we'll
    /// ignore them forward-compatibly):
    ///
    ///     {
    ///       "chat": {
    ///         "reasoning": {
    ///           "supported": true,
    ///           "modes": ["chat", "thinking"],
    ///           "default_mode": "chat",
    ///           "thinking_start": "<think>",
    ///           "thinking_end": "</think>"
    ///         }
    ///       }
    ///     }
    ///
    /// Note: we do NOT set `hasEnableThinkingKwarg: true` here — that flag
    /// is template-driven (does the Jinja template branch on
    /// `enable_thinking | default(...)`). DSV4's chat-encoder module
    /// reads a `thinking_mode` argument directly, so the kwarg flag
    /// stays false; callers plumb thinking-on/off through
    /// `modelOptions["disableThinking"]` as usual and vmlx's
    /// `additionalContext` passes it to whatever renderer the model uses.
    static func readJangConfigReasoning(at dir: URL) -> Capability? {
        let url = dir.appendingPathComponent("jang_config.json")
        guard let data = readSmallConfigFile(url) else {
            return nil
        }
        return analyzeJangConfig(data: data)
    }

    /// Pure, testable JSON parse for `jang_config.json`'s
    /// `chat.reasoning` sub-object. Separated from `readJangConfigReasoning`
    /// so unit tests can feed in fixtures without a filesystem.
    static func analyzeJangConfig(data: Data) -> Capability? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let chat = root["chat"] as? [String: Any],
            let reasoning = chat["reasoning"] as? [String: Any],
            let supported = reasoning["supported"] as? Bool,
            supported
        else {
            return nil
        }
        return Capability(
            supportsThinking: true,
            hasEnableThinkingKwarg: false,
            templateInjectsThinkTag: false
        )
    }

    static func readChatTemplate(at dir: URL) -> String? {
        let jinja = dir.appendingPathComponent("chat_template.jinja")
        if let data = readSmallConfigFile(jinja),
            let s = String(data: data, encoding: .utf8)
        {
            return s
        }
        if let sidecar = readChatTemplateSidecar(at: dir),
            isVisionChatTemplate(sidecar),
            !tokenizerConfigTemplateContainsVisionMarker(at: dir)
        {
            return sidecar
        }
        let tokenizerCfg = dir.appendingPathComponent("tokenizer_config.json")
        if let data = readSmallConfigFile(tokenizerCfg),
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

    private static func readChatTemplateSidecar(at dir: URL) -> String? {
        let url = dir.appendingPathComponent("chat_template.json")
        guard let data = readSmallConfigFile(url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let template = obj["chat_template"] as? String
        else {
            return nil
        }
        return template
    }

    private static func tokenizerConfigTemplateContainsVisionMarker(at dir: URL) -> Bool {
        guard let template = readTokenizerConfigTemplate(at: dir) else {
            return false
        }
        return isVisionChatTemplate(template)
    }

    private static func readTokenizerConfigTemplate(at dir: URL) -> String? {
        let tokenizerCfg = dir.appendingPathComponent("tokenizer_config.json")
        guard let data = readSmallConfigFile(tokenizerCfg),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let tmpl = obj["chat_template"] as? String { return tmpl }
        if let arr = obj["chat_template"] as? [[String: Any]],
            let first = arr.first,
            let tmpl = first["template"] as? String
        {
            return tmpl
        }
        return nil
    }

    private static func readSmallConfigFile(_ url: URL, maxBytes: Int = 1_048_576) -> Data? {
        let path = url.path
        return path.withCString { rawPath in
            let fd = Darwin.open(rawPath, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { Darwin.close(fd) }

            var statBuffer = stat()
            guard Darwin.fstat(fd, &statBuffer) == 0,
                (statBuffer.st_mode & S_IFMT) == S_IFREG,
                statBuffer.st_size >= 0,
                statBuffer.st_size <= maxBytes
            else {
                return nil
            }

            var data = Data(count: Int(statBuffer.st_size))
            let count = data.count
            guard count > 0 else { return Data() }
            let readCount = data.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, count)
            }
            guard readCount == count else { return nil }
            return data
        }
    }

    private static func isVisionChatTemplate(_ template: String) -> Bool {
        template.contains("<|vision_start|>")
            || template.contains("<|image_pad|>")
            || template.contains("<|video_pad|>")
            || template.contains("<|image|>")
            || template.contains("<image>")
    }
}
