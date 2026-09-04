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

    // MARK: - defaultThinkingOn (drives the UI chip for untouched models)

    /// Ornith / Qwen3 gate the NON-thinking branch on an explicit false
    /// (`enable_thinking is false`), so an absent kwarg means thinking-ON.
    /// The chip must show ON for a fresh ornith, not the old hardcoded OFF.
    @Test("Ornith/Qwen3 negative-gate template defaults thinking ON")
    func ornithDefaultsThinkingOn() {
        let template = """
            {%- if enable_thinking is defined and enable_thinking is false %}
                {{- '<think>\\n\\n</think>\\n\\n' }}
            {%- else %}
                {{- '<think>\\n' }}
            {%- endif %}
            """
        let cap = LocalReasoningCapability.analyze(template: template)
        #expect(cap.isToggleableThinking)
        #expect(cap.defaultThinkingOn)
    }

    /// Gemma-4 gates the THINKING branch on an explicit truthy value
    /// (`... and enable_thinking`) with no `is false` form, so an absent
    /// kwarg means thinking-OFF. The chip must show OFF for a fresh gemma.
    @Test("Gemma-4 positive-gate template defaults thinking OFF")
    func gemma4DefaultsThinkingOff() {
        let template = """
            {%- if (enable_thinking is defined and enable_thinking) or tools -%}
                {%- if enable_thinking is defined and enable_thinking -%}
                    {{- '<|think|>\\n' -}}
                {%- endif -%}
            {%- endif -%}
            """
        let cap = LocalReasoningCapability.analyze(template: template)
        #expect(cap.isToggleableThinking)
        #expect(!cap.defaultThinkingOn)
    }

    /// An explicit Jinja `default(true)` filter is authoritative over the
    /// gate-shape heuristic.
    @Test("enable_thinking | default(true) ⇒ defaults ON")
    func explicitDefaultTrue() {
        let template = "{%- set et = enable_thinking | default(true) -%}<think>{%- endif -%}"
        #expect(LocalReasoningCapability.detectDefaultThinkingOn(template.lowercased()))
    }

    /// `default(false)` filter ⇒ defaults OFF even if other markers exist.
    @Test("enable_thinking | default(false) ⇒ defaults OFF")
    func explicitDefaultFalse() {
        let template = "{%- set et = enable_thinking | default(false) -%}<think>{%- endif -%}"
        #expect(!LocalReasoningCapability.detectDefaultThinkingOn(template.lowercased()))
    }

    /// Nemotron-H uses a ternary default: the `else True` clause is the
    /// value when the kwarg is absent ⇒ defaults thinking-ON.
    @Test("Nemotron ternary `... is defined else True` ⇒ defaults ON")
    func nemotronTernaryDefaultOn() {
        let template =
            "{%- set enable_thinking = enable_thinking if enable_thinking is defined else True %}<think>"
        #expect(LocalReasoningCapability.detectDefaultThinkingOn(template.lowercased()))
    }

    @Test("Ternary `... is defined else False` ⇒ defaults OFF")
    func ternaryDefaultOff() {
        let template =
            "{%- set enable_thinking = enable_thinking if enable_thinking is defined else False %}<think>"
        #expect(!LocalReasoningCapability.detectDefaultThinkingOn(template.lowercased()))
    }

    // MARK: - Raptor / Bailing V3 normalisation block

    /// Raptor-v0.5-8B-A1B (Bailing V3 / Ling 3 template): the template
    /// normalises `enable_thinking` into a `thinking_option` string and the
    /// undefined-kwarg fallback (`elif thinking_option is not defined`) sets
    /// it to `'on'`. No `default(...)` filter, no ternary, no `is false`
    /// gate — the old detector fell through to OFF and the chip lied.
    static let raptorTemplateExcerpt = """
        {#- Bailing V3 chat template -#}
        {#- Supports: thinking option, tool calling -#}

        {#- ==================== thinking option normalization ==================== -#}
        {%- if enable_thinking is defined %}
        {%- if enable_thinking %}
        {%- set thinking_option = 'on' %}
        {%- else %}
        {%- set thinking_option = 'off' %}
        {%- endif %}
        {%- elif thinking_option is not defined %}
        {%- set thinking_option = 'on' %}
        {%- endif %}

        {#- ==================== preserved thinking  ==================== -#}
        {% set preserved_thinking = true %}

        {#- ==================== generation prompt ==================== -#}
        {%- if add_generation_prompt %}
            {{- '<role>ASSISTANT</role>' }}
            {%- if thinking_option == 'on' %}
                {{- '\n<think>' }}
            {%- elif thinking_option == 'off' %}
                {{- '\n<think></think>' }}
            {%- endif %}
        {%- endif %}
        """

    @Test("Raptor normalisation block: undefined kwarg ⇒ thinking_option='on' ⇒ defaults ON")
    func raptorTemplateDefaultsThinkingOn() {
        let cap = LocalReasoningCapability.analyze(template: Self.raptorTemplateExcerpt)
        #expect(cap.supportsThinking)
        #expect(cap.hasEnableThinkingKwarg)
        #expect(cap.isToggleableThinking)
        #expect(cap.defaultThinkingOn)
        // Template-inferred: not a `generation_config` declaration.
        #expect(cap.declaredDefaultThinkingOn == nil)
    }

    @Test("Normalisation block whose fallback sets 'off' ⇒ defaults OFF")
    func normalisationFallbackOffDefaultsOff() {
        let template = """
            {%- if enable_thinking is defined %}
            {%- if enable_thinking %}{%- set thinking_option = 'on' %}{%- else %}{%- set thinking_option = 'off' %}{%- endif %}
            {%- else %}
            {%- set thinking_option = 'off' %}
            {%- endif %}
            {%- if thinking_option == 'on' %}{{- '<think>' }}{%- else %}{{- '<think></think>' }}{%- endif %}
            """
        #expect(!LocalReasoningCapability.detectDefaultThinkingOn(template.lowercased()))
    }

    @Test("Fallback branch extraction skips the nested inner if/else")
    func fallbackBranchExtractionIsDepthAware() {
        let branch = LocalReasoningCapability.undefinedKwargFallbackBranch(
            Self.raptorTemplateExcerpt.lowercased()
        )
        let text = branch ?? ""
        #expect(branch != nil)
        // The inner `{%- else %}` (which sets 'off') belongs to the nested
        // `if enable_thinking` block and must NOT be mistaken for the
        // fallback branch of the outer `is defined` block.
        #expect(text.contains("set thinking_option = 'on'"))
        #expect(!text.contains("'off'"))
        #expect(LocalReasoningCapability.fallbackBranchTurnsThinkingOn(text) == true)
    }

    @Test("`is defined` guard with no fallback branch ⇒ no verdict (Qwen3 read guard)")
    func isDefinedGuardWithoutFallbackYieldsNothing() {
        let template = "{% if enable_thinking is defined %}{% set x = enable_thinking %}{% endif %}"
        #expect(LocalReasoningCapability.undefinedKwargFallbackBranch(template.lowercased()) == nil)
        // And the existing conventions are untouched: this template has no
        // ON default signal, so it stays OFF.
        #expect(!LocalReasoningCapability.detectDefaultThinkingOn(template.lowercased()))
    }

    /// Raptor's `jang_config.json` carries a TOP-LEVEL `reasoning` block
    /// (no `chat.reasoning`, no `capabilities`) with `"default": "on"`.
    /// `DeclaredReasoningEffort` already reads that block; the chip default
    /// must read it too.
    static let raptorJangConfigExcerpt = Data(
        #"""
        {
          "chat": {
            "sampling_defaults": {"temperature": 0.7, "top_p": 0.95, "top_k": 20},
            "stop_token_ids": [156895],
            "role_framing": {"style": "bailing_v3"}
          },
          "reasoning": {
            "supported": true,
            "parser": "bailing_v3",
            "default": "on",
            "think_in_template": true,
            "enable_kwarg": "enable_thinking",
            "off_is_prefilled_closed_block": true,
            "off_prefill": "<think></think>",
            "preserve_thinking_supported": true,
            "preserve_thinking_default": true
          },
          "tools": {"supported": true, "parser": "bailing_v3_xml_arg"}
        }
        """#.utf8
    )

    @Test("jang_config top-level reasoning.default='on' ⇒ serving default ON")
    func raptorJangConfigTopLevelDefaultOn() {
        #expect(LocalReasoningCapability.jangConfigDefaultThinkingOn(data: Self.raptorJangConfigExcerpt) == true)
        // The template-less fallback reads the same block.
        let cap = LocalReasoningCapability.analyzeJangConfig(data: Self.raptorJangConfigExcerpt)
        #expect(cap?.supportsThinking == true)
        #expect(cap?.defaultThinkingOn == true)
        #expect(cap?.hasEnableThinkingKwarg == false, "the kwarg flag stays template-driven")
    }

    @Test("jang_config top-level reasoning.default='off' ⇒ serving default OFF")
    func jangConfigTopLevelDefaultOff() {
        let data = Data(#"{"reasoning": {"supported": true, "default": "off"}}"#.utf8)
        #expect(LocalReasoningCapability.jangConfigDefaultThinkingOn(data: data) == false)
    }

    @Test("jang_config top-level reasoning without a default key ⇒ nil (template decides)")
    func jangConfigTopLevelWithoutDefaultIsNil() {
        let data = Data(#"{"reasoning": {"supported": true, "parser": "bailing_v3"}}"#.utf8)
        #expect(LocalReasoningCapability.jangConfigDefaultThinkingOn(data: data) == nil)
    }

    @Test("jang_config legacy chat.reasoning default_mode still read")
    func jangConfigLegacyChatReasoningDefaultStillRead() {
        let data = Data(
            #"{"chat": {"reasoning": {"supported": true, "default_mode": "chat"}}}"#.utf8
        )
        #expect(LocalReasoningCapability.jangConfigDefaultThinkingOn(data: data) == false)
    }

    /// End to end on disk: a Raptor-shaped bundle directory (template +
    /// jang_config, no generation_config declaration) resolves to a
    /// toggleable capability whose default is ON, and the ON default is
    /// presentation metadata only — `declaredDefaultThinkingOn` stays nil so
    /// request construction keeps sending nothing until the user chooses.
    @Test("Raptor-shaped bundle directory ⇒ toggleable, default ON, nothing declared")
    func raptorShapedBundleDirectoryDefaultsOn() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raptor-shaped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.raptorTemplateExcerpt.write(
            to: dir.appendingPathComponent("chat_template.jinja"),
            atomically: true,
            encoding: .utf8
        )
        try Self.raptorJangConfigExcerpt.write(to: dir.appendingPathComponent("jang_config.json"))

        let cap = LocalReasoningCapability.detect(at: dir)
        #expect(cap.isToggleableThinking)
        #expect(cap.defaultThinkingOn)
        #expect(cap.declaredDefaultThinkingOn == nil)
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
        #expect(cap?.defaultThinkingOn == false)
    }

    @Test("jang_config default_enabled=true preserves vendor thinking default")
    func jangConfigDefaultEnabledThinkingOn() {
        let data = Data(
            #"""
            {
              "chat": {
                "reasoning": {
                  "supported": true,
                  "parser": "deepseek_r1",
                  "default_enabled": true,
                  "default_mode": "think",
                  "modes": ["think", "no_think"]
                }
              }
            }
            """#.utf8
        )
        let cap = LocalReasoningCapability.analyzeJangConfig(data: data)
        #expect(cap?.supportsThinking == true)
        #expect(cap?.defaultThinkingOn == true)
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

    // MARK: - Generic bundle capability declaration

    @Test("Muse-style capabilities declare a channel without inventing a toggle")
    func declaredMuseReasoningChannel() {
        let data = Data(
            #"""
            {
              "model_type": "muse_glimmer",
              "capabilities": {
                "supports_thinking": true,
                "reasoning_parser": "muse_glimmer",
                "reasoning_control": "reasoning_strength"
              }
            }
            """#.utf8
        )
        let cap = LocalReasoningCapability.analyzeDeclaredCapabilities(data: data)
        #expect(cap?.supportsThinking == true)
        #expect(cap?.hasEnableThinkingKwarg == false)
        #expect(cap?.isToggleableThinking == false)
        #expect(cap?.templateInjectsThinkTag == false)
        #expect(cap?.declaredDefaultThinkingOn == nil)
    }

    @Test("A declared channel supplements template analysis only")
    func declaredChannelMergesWithoutFabricatingTemplateMechanics() throws {
        let template = LocalReasoningCapability.analyze(
            template: "Reasoning strength: {{ reasoning_strength | default('high') }}"
        )
        let declared = try #require(
            LocalReasoningCapability.analyzeDeclaredCapabilities(
                data: Data(#"{"capabilities":{"supports_thinking":true}}"#.utf8)
            )
        )
        let merged = LocalReasoningCapability.merge(
            templateCapability: template,
            declaredCapability: declared
        )
        #expect(merged.supportsThinking)
        #expect(!merged.hasEnableThinkingKwarg)
        #expect(!merged.templateInjectsThinkTag)
        #expect(!merged.isToggleableThinking)
        #expect(merged.declaredDefaultThinkingOn == nil)
    }

    @Test("Missing or false supports_thinking is not a capability declaration")
    func absentDeclaredReasoningChannel() {
        #expect(
            LocalReasoningCapability.analyzeDeclaredCapabilities(
                data: Data(#"{"capabilities":{"supports_thinking":false}}"#.utf8)
            ) == nil
        )
        #expect(
            LocalReasoningCapability.analyzeDeclaredCapabilities(
                data: Data(#"{"capabilities":{"reasoning_parser":"muse_glimmer"}}"#.utf8)
            ) == nil
        )
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

    @Test("Filesystem: config capabilities surface a non-toggle reasoning channel")
    func filesystemDeclaredReasoningCapability() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "osaurus-reasoning-declared-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tmp,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        try #"{"capabilities":{"supports_thinking":true,"reasoning_parser":"muse_glimmer"}}"#
            .write(
                to: tmp.appendingPathComponent("config.json"),
                atomically: true,
                encoding: .utf8
            )

        let cap = LocalReasoningCapability.readDeclaredReasoningCapability(at: tmp)
        #expect(cap?.supportsThinking == true)
        #expect(cap?.isToggleableThinking == false)
    }

    @Test("Filesystem: VLM chat_template.json sidecar wins when tokenizer_config is text-only")
    func filesystemVisionSidecarWinsOverTextOnlyTokenizerTemplate() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "osaurus-reasoning-vlm-sidecar-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tmp,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        try #"""
        {"chat_template": "{% for m in messages %}<|im_start|>{{ m.role }}\n{{ m.content }}<|im_end|>{% endfor %}"}
        """#.write(
            to: tmp.appendingPathComponent("tokenizer_config.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"""
        {"chat_template": "{% for m in messages %}<|vision_start|><|image_pad|><|vision_end|>{{ m.content }}<|im_end|>{% endfor %}"}
        """#.write(
            to: tmp.appendingPathComponent("chat_template.json"),
            atomically: true,
            encoding: .utf8
        )

        let template = try #require(LocalReasoningCapability.readChatTemplate(at: tmp))
        #expect(template.contains("<|vision_start|>"))
        #expect(template.contains("<|image_pad|>"))
        #expect(!LocalReasoningCapability.analyze(template: template).isToggleableThinking)
    }
}
