//
//  LocalReasoningCapabilityTests.swift
//

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
    }
}
