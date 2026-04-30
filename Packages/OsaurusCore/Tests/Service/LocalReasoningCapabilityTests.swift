//
//  LocalReasoningCapabilityTests.swift
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("LocalReasoningCapability template analysis")
struct LocalReasoningCapabilityTests {
    @Test("MiniMax-style template: injects <think>, has enable_thinking kwarg")
    func minimaxStyle() {
        let template = """
            {%- if enable_thinking is defined and enable_thinking is false -%}
            {%- else -%}
            {{- '<think>' ~ '\\n' }}
            {%- endif -%}
            """
        let cap = LocalReasoningCapability.analyze(template: template)
        #expect(cap.supportsThinking)
        #expect(cap.hasEnableThinkingKwarg)
        #expect(cap.templateInjectsThinkTag)
        #expect(cap.isToggleableThinking)
    }

    @Test("Qwen3-style: supports thinking but no template-side injection")
    func qwenStyle() {
        let template = """
            {% if message.role == 'assistant' %}
            {% if '</think>' in content %}{% set content = content.split('</think>')[-1] %}{% endif %}
            {% endif %}
            {% if enable_thinking is defined %}{% endif %}
            """
        let cap = LocalReasoningCapability.analyze(template: template)
        #expect(cap.supportsThinking)
        #expect(cap.hasEnableThinkingKwarg)
        #expect(!cap.templateInjectsThinkTag)
        #expect(cap.isToggleableThinking)
    }

    @Test("Non-reasoning template: all signals false")
    func nonReasoningStyle() {
        let template = """
            {% for m in messages %}<|user|>{{ m.content }}<|assistant|>{% endfor %}
            """
        let cap = LocalReasoningCapability.analyze(template: template)
        #expect(!cap.supportsThinking)
        #expect(!cap.hasEnableThinkingKwarg)
        #expect(!cap.templateInjectsThinkTag)
        #expect(!cap.isToggleableThinking)
    }

    @Test("enable_thinking alone is not enough for a UI toggle")
    func enableThinkingWithoutRecognizedThinkingMarkers() {
        let template = """
            {%- if enable_thinking is defined and enable_thinking -%}
            {{- '<|reason|>' -}}
            {%- endif -%}
            """
        let cap = LocalReasoningCapability.analyze(template: template)
        #expect(!cap.supportsThinking)
        #expect(cap.hasEnableThinkingKwarg)
        #expect(!cap.templateInjectsThinkTag)
        #expect(!cap.isToggleableThinking)
    }

    @Test("GLM-flash style: emits </think> without injection (middleware-needed)")
    func glmFlashStyle() {
        // Template references </think> in close-path but never injects <think>
        // into the prompt tail — model will emit </think> without an opener,
        // which is the middleware's prepend-think trigger condition.
        let template = """
            {%- if '</think>' in content %}{% set content = content.split('</think>')[-1] %}{% endif -%}
            """
        let cap = LocalReasoningCapability.analyze(template: template)
        #expect(cap.supportsThinking)
        #expect(!cap.hasEnableThinkingKwarg)
        #expect(!cap.templateInjectsThinkTag)
        #expect(!cap.isToggleableThinking)
    }

    /// Gemma-4's chat_template.jinja opens thinking with the pipe-wrapped
    /// `<|think|>` token, not the plain `<think>` tag. Before this case was
    /// added, `supportsThinking` returned `false` for Gemma-4 because
    /// `contains("<think>")` didn't match, which meant reasoning never
    /// correlated in the UI even when `hasEnableThinkingKwarg: true`.
    @Test("Gemma-4 style: <|think|> pipe-wrapped tag recognised")
    func gemma4Style() {
        // Mirrors the real Gemma-4 template structure: enable_thinking kwarg,
        // `<|think|>` injected inside the system-turn block, no `<think>`.
        let template = """
            {%- if (enable_thinking is defined and enable_thinking) -%}
                {{- '<|turn>system\\n' -}}
                {%- if enable_thinking is defined and enable_thinking -%}
                    {{- '<|think|>' -}}
                {%- endif -%}
            {%- endif -%}
            """
        let cap = LocalReasoningCapability.analyze(template: template)
        #expect(cap.supportsThinking)
        #expect(cap.hasEnableThinkingKwarg)
        #expect(cap.templateInjectsThinkTag)
        #expect(cap.isToggleableThinking)
    }

    // MARK: - jang_config.json chat.reasoning fallback (DSV4-class bundles)

    /// DSV4-Flash ships NO chat_template in tokenizer_config.json — the
    /// template lives in a Python module `encoding/encoding_dsv4.py` that
    /// only the Python / Swift runtime knows about. Without a fallback,
    /// `LocalReasoningCapability.detect()` returned `.none`, `supportsThinking`
    /// flipped to false, and PR #934's `streamWithTools` coercion merged
    /// DSV4's `.reasoning` deltas into content — the thinking split was
    /// destroyed. Fallback reads `jang_config.json > chat > reasoning.supported`
    /// from the bundle root.
    @Test("jang_config fallback: DSV4 reasoning.supported=true → supportsThinking")
    func jangConfigDSV4Reasoning() {
        let data = Data(
            #"""
            {
              "model_family": "deepseek_v4",
              "chat": {
                "encoder": "encoding_dsv4",
                "chat_template_source": "builtin_encoding_module",
                "has_tokenizer_chat_template": false,
                "reasoning": {
                  "supported": true,
                  "modes": ["chat", "thinking"],
                  "default_mode": "chat",
                  "thinking_start": "<think>",
                  "thinking_end": "</think>"
                },
                "tool_calling": {"parser": "dsml"}
              }
            }
            """#.utf8
        )
        let cap = LocalReasoningCapability.analyzeJangConfig(data: data)
        #expect(cap?.supportsThinking == true)
        // `enable_thinking` kwarg is Jinja-template driven; DSV4's
        // Python encoder takes `thinking_mode` as a positional argument
        // instead, so the kwarg flag stays false.
        #expect(cap?.hasEnableThinkingKwarg == false)
        #expect(cap?.isToggleableThinking == false)
        // DSV4's template is outside the bundle (Python module) — vmlx
        // injects the thinking tag itself when the caller picks thinking
        // mode. From osaurus's perspective there is no on-disk Jinja to
        // analyse for an injection regex, so this signal is false.
        #expect(cap?.templateInjectsThinkTag == false)
    }

    @Test("jang_config: reasoning.supported=false → nil (fall through to .none)")
    func jangConfigReasoningNotSupported() {
        // A bundle that declares reasoning explicitly unsupported. The
        // fallback returns nil so `detect()` returns `.none` and the
        // rest of the pipeline routes `.chunk` events as content.
        let data = Data(
            #"""
            {"chat": {"reasoning": {"supported": false}}}
            """#.utf8
        )
        #expect(LocalReasoningCapability.analyzeJangConfig(data: data) == nil)
    }

    @Test("jang_config: missing chat subtree → nil")
    func jangConfigNoChatSubtree() {
        // Older JANG bundles with only quantization / source_model metadata.
        let data = Data(
            #"""
            {
              "quantization": {"profile": "JANG_2L"},
              "source_model": {"name": "Qwen3.5-122B-A10B"}
            }
            """#.utf8
        )
        #expect(LocalReasoningCapability.analyzeJangConfig(data: data) == nil)
    }

    @Test("jang_config: chat present but no reasoning sub-object → nil")
    func jangConfigChatWithoutReasoning() {
        let data = Data(
            #"""
            {"chat": {"tool_calling": {"parser": "dsml"}}}
            """#.utf8
        )
        #expect(LocalReasoningCapability.analyzeJangConfig(data: data) == nil)
    }

    @Test("jang_config: malformed JSON → nil (does not throw)")
    func jangConfigMalformed() {
        let data = Data("not json".utf8)
        #expect(LocalReasoningCapability.analyzeJangConfig(data: data) == nil)
    }

    // MARK: - Filesystem integration

    /// End-to-end: scratch directory with NO chat template but WITH a
    /// jang_config that declares reasoning support — the DSV4 shape.
    /// `readJangConfigReasoning(at:)` must hit disk, parse, and return
    /// a capability with `supportsThinking = true`.
    @Test("Filesystem: DSV4-shaped bundle (no chat template, jang_config reasoning)")
    func filesystemDSV4Shape() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "osaurus-reasoning-dsv4-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tmp,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        try #"""
        {"chat": {"reasoning": {"supported": true}}}
        """#.write(
            to: tmp.appendingPathComponent("jang_config.json"),
            atomically: true,
            encoding: .utf8
        )

        let cap = LocalReasoningCapability.readJangConfigReasoning(at: tmp)
        #expect(cap?.supportsThinking == true)
    }

    @Test("Filesystem: missing jang_config.json returns nil, does not throw")
    func filesystemNoJangConfig() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "osaurus-reasoning-empty-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tmp,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(LocalReasoningCapability.readJangConfigReasoning(at: tmp) == nil)
    }
}
