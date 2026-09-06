//
//  DeclaredReasoningEffortTests.swift
//  osaurus
//
//  Qwen3.8's `reasoning_effort` chat-template kwarg accepts ONLY
//  low/medium/xhigh — the template `raise_exception`s on anything else, and
//  the adapter used to forward the app's generic ladder (`high`, `max`)
//  verbatim, hard-failing the prompt render. These tests pin the stamped
//  jang_config contract, the snapping policy, the template-derived fallback
//  for raw HF bundles, and the dispatch behavior end to end.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct DeclaredReasoningEffortTests {

    private func withOverride<T>(
        _ declaration: DeclaredReasoningEffort.Declaration?,
        forModelId targetId: String,
        _ body: () throws -> T
    ) rethrows -> T {
        DeclaredReasoningEffort.testDeclarationOverride = { modelId in
            modelId == targetId ? declaration : nil
        }
        defer { DeclaredReasoningEffort.testDeclarationOverride = nil }
        return try body()
    }

    // MARK: - jang_config parsing

    @Test("the full Qwen3.8 stamp parses: levels, default, preserve_thinking")
    func parsesStampedTopLevelReasoningBlock() {
        let json = """
            {
              "reasoning": {
                "supported": true,
                "supported_reasoning_efforts": ["low", "medium", "xhigh"],
                "default_reasoning_effort": "xhigh",
                "reasoning_effort_transport": "chat_template_kwarg",
                "preserve_thinking_supported": true,
                "preserve_thinking_default": true,
                "preserve_thinking_transport": "chat_template_kwarg"
              }
            }
            """
        let declared = DeclaredReasoningEffort.parseJangDeclaration(data: Data(json.utf8))
        #expect(
            declared?.control
                == .levels(["low", "medium", "xhigh"], defaultLevel: "xhigh"))
        #expect(declared?.preserveThinking?.defaultOn == true)
    }

    @Test("a chat-nested legacy block (DSV4 shape) means NO effort control, not unconstrained")
    func chatNestedLegacyBlockIsNoEffortControl() {
        // DSV4-Flash's real stamp shape: `chat.reasoning` with the OLD
        // `reasoning_effort_levels` key. Absence of the new
        // `supported_reasoning_efforts` key = the model has no
        // template-kwarg effort control; the kwarg must be omitted.
        let json = """
            {
              "chat": {
                "reasoning": {
                  "supported": true,
                  "default_effort": "low",
                  "reasoning_effort_levels": ["low", "high", "max"]
                }
              }
            }
            """
        let declared = DeclaredReasoningEffort.parseJangDeclaration(data: Data(json.utf8))
        #expect(declared?.control == .noEffortControl)
        #expect(declared?.preserveThinking == nil)
    }

    @Test("an unrecognized transport downgrades to no-control instead of guessing delivery")
    func unknownTransportDowngrades() {
        let json = """
            {
              "reasoning": {
                "supported_reasoning_efforts": ["low", "medium", "xhigh"],
                "reasoning_effort_transport": "api_field",
                "preserve_thinking_supported": true,
                "preserve_thinking_transport": "python_encoder"
              }
            }
            """
        let declared = DeclaredReasoningEffort.parseJangDeclaration(data: Data(json.utf8))
        #expect(declared?.control == .noEffortControl)
        #expect(declared?.preserveThinking == nil)
    }

    @Test("no reasoning block at all defers to the template fallback")
    func missingBlockReturnsNil() {
        let json = """
            {"sampling_defaults": {"temperature": 1.0}}
            """
        #expect(DeclaredReasoningEffort.parseJangDeclaration(data: Data(json.utf8)) == nil)
    }

    // MARK: - Snapping

    @Test("ladder snapping: ties round up, extremes clamp, unknowns pass through")
    func snappingPolicy() {
        let levels = ["low", "medium", "xhigh"]
        // `high` is equidistant from medium and xhigh — the user asked for
        // more than medium, so the tie resolves upward.
        #expect(DeclaredReasoningEffort.snapped("high", ontoLevels: levels, defaultLevel: "xhigh") == "xhigh")
        #expect(DeclaredReasoningEffort.snapped("max", ontoLevels: levels, defaultLevel: "xhigh") == "xhigh")
        #expect(DeclaredReasoningEffort.snapped("minimal", ontoLevels: levels, defaultLevel: "xhigh") == "low")
        #expect(DeclaredReasoningEffort.snapped("medium", ontoLevels: levels, defaultLevel: "xhigh") == "medium")
        #expect(DeclaredReasoningEffort.snapped("XHigh", ontoLevels: levels, defaultLevel: "xhigh") == "xhigh")
        #expect(DeclaredReasoningEffort.snapped("highest", ontoLevels: levels, defaultLevel: "xhigh") == "xhigh")
        // Unknown strings are NOT coerced — the caller forwards them so the
        // template's own raise (naming the valid set) surfaces.
        #expect(DeclaredReasoningEffort.snapped("banana", ontoLevels: levels, defaultLevel: "xhigh") == nil)
    }

    // MARK: - Template-derived fallback (raw HF bundles)

    @Test("the accepted set parses straight out of Qwen3.8's raise guard")
    func templateDerivedFromQwen38Guard() {
        // Verbatim from Qwen/Qwen3.8-27B chat_template.jinja.
        let template = """
            {%- set reasoning_instructions = '' %}
            {%- if enable_thinking is undefined or enable_thinking is true %}
                {%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
                {%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
                    {{- raise_exception('Unexpected reasoning effort ' ~ reasoning_effort ~ '. Supported types are xhigh (default), medium, and low.') }}
                {%- endif %}
            {%- endif %}
            {%- if preserve_thinking is undefined or preserve_thinking is true %}
            {%- endif %}
            """
        let declared = DeclaredReasoningEffort.templateDerivedDeclaration(template: template)
        // Tuple order in the guard is presentation-arbitrary; the derived
        // levels come back in ascending ladder order for direct UI use.
        #expect(
            declared?.control
                == .levels(["low", "medium", "xhigh"], defaultLevel: "xhigh"))
        #expect(declared?.preserveThinking != nil)
    }

    @Test("templates that never read the kwarg derive nothing")
    func templateWithoutEffortDerivesNil() {
        let qwen36ish = """
            {%- if enable_thinking is false %}{{ '<|im_start|>assistant\\n' }}{%- endif %}
            """
        #expect(DeclaredReasoningEffort.templateDerivedDeclaration(template: qwen36ish) == nil)
    }

    // MARK: - UI capability bridge

    @Test("declared levels reach the picker as None + the exact stamped set")
    func capabilitiesBridgePrependsOffRail() {
        let modelId = "JANGQ-AI/Qwen3.8-27B-MXFP8"
        let declared = DeclaredReasoningEffort.Declaration(
            control: .levels(["low", "medium", "xhigh"], defaultLevel: "xhigh"),
            preserveThinking: .init(defaultOn: true)
        )
        withOverride(declared, forModelId: modelId) {
            let capabilities = ModelProfileRegistry.reasoningCapabilities(for: modelId)
            #expect(capabilities?.levels.map(\.id) == ["none", "low", "medium", "xhigh"])
            #expect(capabilities?.defaultLevelId == "xhigh")

            // The registry's option pipeline now constrains the segment set,
            // so a persisted `high` (valid on other models) is dropped
            // instead of reaching the wire.
            let options = ModelProfileRegistry.options(for: modelId)
            #expect(options.count == 1)
            #expect(options.first?.id == "reasoningEffort")
            let normalized = ModelProfileRegistry.normalizedOptions(
                for: modelId,
                persisted: ["reasoningEffort": .string("high")]
            )
            #expect(normalized["reasoningEffort"] == nil)
            let kept = ModelProfileRegistry.normalizedOptions(
                for: modelId,
                persisted: ["reasoningEffort": .string("medium")]
            )
            #expect(kept["reasoningEffort"] == .string("medium"))
        }
    }

    // MARK: - Dispatch (MLXBatchAdapter.additionalContext)

    private static let qwen38Id = "JANGQ-AI/Qwen3.8-27B-MXFP8"

    private func dispatchContext(
        effort: String? = nil,
        preserveThinking: Bool? = nil,
        declaration: DeclaredReasoningEffort.Declaration?
    ) -> [String: any Sendable] {
        var options: [String: ModelOptionValue] = [:]
        if let effort { options["reasoningEffort"] = .string(effort) }
        if let preserveThinking { options["preserveThinking"] = .bool(preserveThinking) }
        let generation = GenerationParameters(
            temperature: nil, maxTokens: 256, modelOptions: options)
        return withOverride(declaration, forModelId: Self.qwen38Id) {
            MLXBatchAdapter.additionalContext(
                for: generation, modelName: Self.qwen38Id)
        }
    }

    private static let stampedDeclaration = DeclaredReasoningEffort.Declaration(
        control: .levels(["low", "medium", "xhigh"], defaultLevel: "xhigh"),
        preserveThinking: .init(defaultOn: true)
    )

    @Test("dispatch snaps `high` onto the declared set instead of hard-failing the render")
    func adapterSnapsQwenEffort() {
        let context = dispatchContext(effort: "high", declaration: Self.stampedDeclaration)
        #expect(context["reasoning_effort"] as? String == "xhigh")
        #expect(context["enable_thinking"] as? Bool == true)
    }

    @Test("a keyless stamped bundle sends NO effort kwarg but keeps thinking on")
    func adapterOmitsEffortWhenBundleDeclaresNoControl() {
        let declared = DeclaredReasoningEffort.Declaration(
            control: .noEffortControl, preserveThinking: nil)
        let context = dispatchContext(effort: "high", declaration: declared)
        #expect(context["reasoning_effort"] == nil)
        #expect(context["enable_thinking"] as? Bool == true)
    }

    @Test("undeclared bundles keep legacy verbatim forwarding")
    func adapterKeepsLegacyForwardingWithoutDeclaration() {
        let context = dispatchContext(effort: "high", declaration: nil)
        #expect(context["reasoning_effort"] as? String == "high")
        #expect(context["enable_thinking"] as? Bool == true)
    }

    @Test("an unknown explicit effort is forwarded so the template's own raise surfaces")
    func adapterForwardsUnknownEffortVerbatim() {
        let context = dispatchContext(effort: "banana", declaration: Self.stampedDeclaration)
        #expect(context["reasoning_effort"] as? String == "banana")
    }

    @Test("the direct rail still wins over any declared level set")
    func adapterDirectRailStillWins() {
        let context = dispatchContext(effort: "none", declaration: Self.stampedDeclaration)
        #expect(context["enable_thinking"] as? Bool == false)
        #expect(context["reasoning_effort"] == nil)
    }

    @Test("preserve_thinking is sent only when the bundle declares the kwarg")
    func adapterGatesPreserveThinkingOnDeclaration() {
        let declaredOff = dispatchContext(
            effort: "medium", preserveThinking: false, declaration: Self.stampedDeclaration)
        #expect(declaredOff["preserve_thinking"] as? Bool == false)
        #expect(declaredOff["reasoning_effort"] as? String == "medium")

        let undeclared = dispatchContext(effort: "medium", preserveThinking: false, declaration: nil)
        #expect(undeclared["preserve_thinking"] == nil)
    }
    @Test("history_reasoning: omit is parsed; absent means keep")
    func historyReasoningOmitParses() {
        let omit = """
            { "reasoning": { "supported": true, "history_reasoning": "omit" } }
            """
        #expect(DeclaredReasoningEffort.parseJangDeclaration(data: Data(omit.utf8))?.historyReasoningOmitted == true)
        let keep = """
            { "reasoning": { "supported": true, "preserve_thinking_supported": true } }
            """
        #expect(DeclaredReasoningEffort.parseJangDeclaration(data: Data(keep.utf8))?.historyReasoningOmitted == false)
    }
    @Test("Raptor stamp inserts history_reasoning: omit textually, verified, idempotent, scoped")
    func raptorStampRewritesOnlyWhatItMust() {
        let original = """
            {
              "chat": { "sampling_defaults": { "temperature": 0.7 } },
              "reasoning": {
                "supported": true,
                "parser": "bailing_v3",
                "preserve_thinking_default": true,
                "preserve_thinking_transport": "template_constant"
              },
              "tools": { "format": "xml_arg" }
            }
            """
        let stamped = RaptorHistoryReasoningStamp.stamped(original)
        #expect(stamped != nil)
        #expect(stamped?.contains("\"reasoning\": {\n    \"history_reasoning\": \"omit\",\n    \"supported\": true") == true)
        // Parses, key in place, everything else untouched.
        let root = stamped.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect((root?["reasoning"] as? [String: Any])?["history_reasoning"] as? String == "omit")
        #expect((root?["reasoning"] as? [String: Any])?["parser"] as? String == "bailing_v3")
        #expect((root?["tools"] as? [String: Any])?["format"] as? String == "xml_arg")
        #expect(DeclaredReasoningEffort.parseJangDeclaration(data: Data(stamped!.utf8))?.historyReasoningOmitted == true)
        // Idempotent: a stamped file is left alone.
        #expect(RaptorHistoryReasoningStamp.stamped(stamped!) == nil)
        // No reasoning block → nothing to do; empty block → valid JSON without a trailing comma.
        #expect(RaptorHistoryReasoningStamp.stamped(#"{"chat": {}}"#) == nil)
        let empty = RaptorHistoryReasoningStamp.stamped("{\n  \"reasoning\": {\n  }\n}")
        #expect(empty != nil)
        #expect((empty.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["reasoning"] as? [String: Any])?["history_reasoning"] as? String == "omit")
        // Scope: the validated legacy family only — OsaurusAI/Raptor-v0.5 and its
        // dash-suffixed variants, case-insensitive. Not the bare repo, not Raptor 0.6
        // (Nanbeige), not a repo that merely starts with "Raptor", not other orgs or families.
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M"))
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "osaurusai/raptor-v0.5-8b-a1b-jang_6m-rtn"))
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "OsaurusAI/Raptor-v0.5"))
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "OsaurusAI/Raptor-v0.6-Nanbeige-JANG_6M") == false)
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "osaurusai/raptor-v0.6-8b-a1b-jang_4m") == false)
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "OsaurusAI/Raptor") == false)
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "OsaurusAI/Raptor-v0.55-8B") == false)
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "OsaurusAI/Raptorial-Unrelated") == false)
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "SomeoneElse/Raptor-v0.5") == false)
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "JANGQ-AI/Ling-3.0-tiny-JANG_6M") == false)
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "JANGQ-AI/Ornith-1.5-9B-JANG_4D") == false)
        #expect(RaptorHistoryReasoningStamp.appliesTo(modelId: "JANGQ-AI/Qwen3.8-Flash-Next-JANG_4M") == false)
        // A nested legacy `chat.reasoning` block that precedes the root one in the text
        // is left alone; the key lands on the ROOT reasoning object only.
        let nestedFirst = """
            {
              "chat": { "reasoning": { "legacy": true }, "sampling_defaults": { "temperature": 0.7 } },
              "reasoning": { "supported": true }
            }
            """
        let nestedStamped = RaptorHistoryReasoningStamp.stamped(nestedFirst)
        let nestedRoot = nestedStamped.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect((nestedRoot?["reasoning"] as? [String: Any])?["history_reasoning"] as? String == "omit")
        #expect(((nestedRoot?["chat"] as? [String: Any])?["reasoning"] as? [String: Any])?["history_reasoning"] == nil)
        #expect(((nestedRoot?["chat"] as? [String: Any])?["reasoning"] as? [String: Any])?["legacy"] as? Bool == true)
    }
    /// A bundle directory with the config.json the migration requires
    /// (`model_type: bailing_hybrid`, the Ling architecture Raptor v0.5 is built on).
    private static func writeLingConfig(in dir: URL, modelType: String = "bailing_hybrid") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ \"model_type\": \"\(modelType)\", \"architectures\": [\"BailingMoeV3ForCausalLM\"] }"
            .write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    }

    @Test("stampIfNeeded: Raptor v0.5 on a Ling config only, once per process, never throws on a missing or read-only file")
    func raptorStampIfNeededIsScopedAndSafe() throws {
        RaptorHistoryReasoningStamp.resetForTests()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("raptor-stamp-\(UUID().uuidString)")
        try Self.writeLingConfig(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("jang_config.json")
        try #"{ "reasoning": { "supported": true } }"#.write(to: url, atomically: true, encoding: .utf8)

        // Another family with the same file shape: untouched.
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "JANGQ-AI/Ling-3.0-tiny-JANG_6M", directory: dir) == false)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("history_reasoning") == false)
        // Raptor 0.6 (Nanbeige) under the same org: untouched, by name alone.
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.6-Nanbeige-JANG_6M", directory: dir) == false)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("history_reasoning") == false)
        // A v0.5-named bundle whose config.json is NOT the Ling architecture: untouched,
        // and so is one with no config.json at all — the name never decides alone.
        let nanbeige = dir.appendingPathComponent("nanbeige")
        try Self.writeLingConfig(in: nanbeige, modelType: "nanbeige4")
        try #"{ "reasoning": { "supported": true } }"#.write(to: nanbeige.appendingPathComponent("jang_config.json"), atomically: true, encoding: .utf8)
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: nanbeige) == false)
        #expect(try String(contentsOf: nanbeige.appendingPathComponent("jang_config.json"), encoding: .utf8).contains("history_reasoning") == false)
        let noConfig = dir.appendingPathComponent("noconfig")
        try FileManager.default.createDirectory(at: noConfig, withIntermediateDirectories: true)
        try #"{ "reasoning": { "supported": true } }"#.write(to: noConfig.appendingPathComponent("jang_config.json"), atomically: true, encoding: .utf8)
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: noConfig) == false)
        #expect(try String(contentsOf: noConfig.appendingPathComponent("jang_config.json"), encoding: .utf8).contains("history_reasoning") == false)
        // Raptor: stamped on the first load, memoised afterwards, file stays valid.
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: dir))
        let stamped = try String(contentsOf: url, encoding: .utf8)
        #expect(DeclaredReasoningEffort.parseJangDeclaration(data: Data(stamped.utf8))?.historyReasoningOmitted == true)
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: dir) == false)
        // Missing file / missing directory: false, no throw — and NOT memoised:
        // once the file appears, the same id is stamped on the next call.
        RaptorHistoryReasoningStamp.resetForTests()
        let late = dir.appendingPathComponent("late")
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: late) == false)
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: nil) == false)
        try Self.writeLingConfig(in: late)
        try #"{ "reasoning": { "supported": true } }"#.write(to: late.appendingPathComponent("jang_config.json"), atomically: true, encoding: .utf8)
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: late))
        // Same id relocated/replaced at another directory: its own file gets stamped too
        // (the memo is per id AND resolved directory, not per id alone).
        let moved = dir.appendingPathComponent("moved")
        try Self.writeLingConfig(in: moved)
        try #"{ "reasoning": { "supported": true } }"#.write(to: moved.appendingPathComponent("jang_config.json"), atomically: true, encoding: .utf8)
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: moved))
        #expect(try String(contentsOf: moved.appendingPathComponent("jang_config.json"), encoding: .utf8).contains("history_reasoning"))
    }
    /// The app honours `generation_config.default_chat_template_kwargs.enable_thinking`
    /// as the publisher's declared thinking default; Raptor only declared it in
    /// jang_config, so agent/tool requests on a fresh install ran thinking-off.
    /// The companion stamp inserts the declaration, textually, verified, once.
    @Test("Raptor generation_config stamp declares enable_thinking=true once, preserving everything else")
    func raptorGenerationConfigStamp() throws {
        let original = """
            {
              "do_sample": true,
              "temperature": 0.7,
              "top_p": 0.95,
              "repetition_penalty": 1.05,
              "eos_token_id": 156895
            }
            """
        let stamped = try #require(RaptorHistoryReasoningStamp.stampedGenerationConfig(original))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(stamped.utf8)) as? [String: Any])
        #expect((root["default_chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true)
        #expect(root["temperature"] as? Double == 0.7)
        #expect(root["eos_token_id"] as? Int == 156895)
        #expect(stamped.contains("\"do_sample\": true"))
        #expect(RaptorHistoryReasoningStamp.stampedGenerationConfig(stamped) == nil)  // idempotent
        #expect(RaptorHistoryReasoningStamp.stampedGenerationConfig(#"{"default_chat_template_kwargs": {"enable_thinking": false}}"#) == nil)  // an explicit declaration is never overridden
        #expect(RaptorHistoryReasoningStamp.stampedGenerationConfig(#"{"default_chat_template_kwargs": {"enable_thinking": true}}"#) == nil)
        #expect(RaptorHistoryReasoningStamp.stampedGenerationConfig(#"{"default_chat_template_kwargs": null}"#) == nil)  // not an object: left alone
        #expect(RaptorHistoryReasoningStamp.stampedGenerationConfig(#"{"default_chat_template_kwargs": 3}"#) == nil)
        let empty = try #require(RaptorHistoryReasoningStamp.stampedGenerationConfig("{}"))
        #expect(((try JSONSerialization.jsonObject(with: Data(empty.utf8)) as? [String: Any])?["default_chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true)

        // An EXISTING kwargs object without the leaf gets only the leaf: an empty object,
        // and one with unrelated kwargs whose siblings must survive byte-for-byte.
        let emptyKwargs = try #require(RaptorHistoryReasoningStamp.stampedGenerationConfig(#"{"default_chat_template_kwargs": {}}"#))
        #expect(((try JSONSerialization.jsonObject(with: Data(emptyKwargs.utf8)) as? [String: Any])?["default_chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true)
        let siblings = """
            {
              "temperature": 0.7,
              "default_chat_template_kwargs": {
                "other_option": true,
                "nested": { "reasoning": { "keep": 1 } }
              }
            }
            """
        let withSiblings = try #require(RaptorHistoryReasoningStamp.stampedGenerationConfig(siblings))
        let siblingRoot = try #require(try JSONSerialization.jsonObject(with: Data(withSiblings.utf8)) as? [String: Any])
        let kwargs = try #require(siblingRoot["default_chat_template_kwargs"] as? [String: Any])
        #expect(kwargs["enable_thinking"] as? Bool == true)
        #expect(kwargs["other_option"] as? Bool == true)
        #expect(((kwargs["nested"] as? [String: Any])?["reasoning"] as? [String: Any])?["keep"] as? Int == 1)
        #expect(siblingRoot["temperature"] as? Double == 0.7)
        #expect(withSiblings.contains("\"other_option\": true,"))  // formatting kept, one line added
        #expect(RaptorHistoryReasoningStamp.stampedGenerationConfig(withSiblings) == nil)  // idempotent

        // On disk: stampIfNeeded on a Raptor dir also stamps generation_config; a fresh
        // LocalReasoningCapability detect then reports the declared default.
        RaptorHistoryReasoningStamp.resetForTests()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("raptor-gc-\(UUID().uuidString)")
        try Self.writeLingConfig(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{ "reasoning": { "supported": true, "default": "on" } }"#.write(to: dir.appendingPathComponent("jang_config.json"), atomically: true, encoding: .utf8)
        try original.write(to: dir.appendingPathComponent("generation_config.json"), atomically: true, encoding: .utf8)
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: dir))
        let gc = try String(contentsOf: dir.appendingPathComponent("generation_config.json"), encoding: .utf8)
        #expect(gc.contains("default_chat_template_kwargs"))
    }

    /// The companion mirrors the bundle's OWN declared default: a jang_config that
    /// declares `reasoning.default: "off"` or declares no default gets NO
    /// generation_config default synthesised (an explicit publisher OFF must never
    /// become ON); only a declared ON is mirrored.
    @Test("Raptor generation_config companion follows the bundle's declared default: off and absent stay untouched")
    func raptorGenerationCompanionFollowsDeclaredDefault() throws {
        for (label, jang, expectStamp) in [
            ("off", #"{ "reasoning": { "supported": true, "default": "off" } }"#, false),
            ("absent", #"{ "reasoning": { "supported": true } }"#, false),
            ("legacy-nested-off", #"{ "reasoning": { "supported": true }, "chat": { "reasoning": { "default": "off" } } }"#, false),
            ("on", #"{ "reasoning": { "supported": true, "default": "on" } }"#, true),
            ("default_enabled", #"{ "reasoning": { "supported": true, "default_enabled": true } }"#, true),
        ] {
            RaptorHistoryReasoningStamp.resetForTests()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("raptor-gc-default-\(UUID().uuidString)")
            try Self.writeLingConfig(in: dir)
            defer { try? FileManager.default.removeItem(at: dir) }
            try jang.write(to: dir.appendingPathComponent("jang_config.json"), atomically: true, encoding: .utf8)
            try "{}".write(to: dir.appendingPathComponent("generation_config.json"), atomically: true, encoding: .utf8)
            // The history stamp itself is unconditional for an eligible bundle…
            #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: dir), Comment(rawValue: label))
            #expect(try String(contentsOf: dir.appendingPathComponent("jang_config.json"), encoding: .utf8).contains("history_reasoning"), Comment(rawValue: label))
            // …the companion only where the bundle declares ON.
            let gc = try String(contentsOf: dir.appendingPathComponent("generation_config.json"), encoding: .utf8)
            #expect(gc.contains("enable_thinking") == expectStamp, Comment(rawValue: "\(label): \(gc)"))
            if !expectStamp { #expect(gc == "{}", Comment(rawValue: label)) }
            // Settled either way: a second call in the same process writes nothing more.
            #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: dir) == false, Comment(rawValue: label))
            #expect(try String(contentsOf: dir.appendingPathComponent("generation_config.json"), encoding: .utf8) == gc, Comment(rawValue: label))
        }
        // Pure outcome: explicit generation-config declarations are reported as such, not rewritten.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("raptor-gc-explicit-\(UUID().uuidString)")
        try Self.writeLingConfig(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let explicitOff = #"{"default_chat_template_kwargs": {"enable_thinking": false}}"#
        try explicitOff.write(to: dir.appendingPathComponent("generation_config.json"), atomically: true, encoding: .utf8)
        let on = #"{ "reasoning": { "default": "on", "history_reasoning": "omit" } }"#
        #expect(RaptorHistoryReasoningStamp.stampGenerationConfig(in: dir, jangConfigText: on) == .alreadyDeclared)
        #expect(try String(contentsOf: dir.appendingPathComponent("generation_config.json"), encoding: .utf8) == explicitOff)
        #expect(RaptorHistoryReasoningStamp.stampGenerationConfig(in: dir, jangConfigText: #"{ "reasoning": { "default": "off" } }"#) == .notApplicable)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("generation_config.json"))
        #expect(RaptorHistoryReasoningStamp.stampGenerationConfig(in: dir, jangConfigText: on) == .retryable)
    }

    /// The two files are memoised independently: a jang_config that already carries
    /// the key with a generation_config that is missing (or unwritable) at first is
    /// repaired on the NEXT load in the same process, once the file is there.
    @Test("Raptor companion stamp retries a missing generation_config in the same process; a repaired file is not rewritten again")
    func raptorGenerationCompanionRetriesAfterMissingFile() throws {
        RaptorHistoryReasoningStamp.resetForTests()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("raptor-gc-retry-\(UUID().uuidString)")
        try Self.writeLingConfig(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jangURL = dir.appendingPathComponent("jang_config.json")
        let gcURL = dir.appendingPathComponent("generation_config.json")
        let alreadyStamped = #"{ "reasoning": { "supported": true, "default": "on", "history_reasoning": "omit" } }"#
        try alreadyStamped.write(to: jangURL, atomically: true, encoding: .utf8)

        // No generation_config yet: nothing to write, nothing memoised for it.
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: dir) == false)
        #expect(FileManager.default.fileExists(atPath: gcURL.path) == false)
        #expect(try String(contentsOf: jangURL, encoding: .utf8) == alreadyStamped)

        // The file appears (download completes, volume mounts): the very next call repairs it.
        try "{}".write(to: gcURL, atomically: true, encoding: .utf8)
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: dir) == false)  // jang untouched
        let repaired = try String(contentsOf: gcURL, encoding: .utf8)
        #expect(((try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any])?["default_chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true)
        #expect(try String(contentsOf: jangURL, encoding: .utf8) == alreadyStamped)

        // Settled now: a later call leaves both files byte-identical.
        let before = try Data(contentsOf: gcURL)
        #expect(RaptorHistoryReasoningStamp.stampIfNeeded(modelId: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M", directory: dir) == false)
        #expect(try Data(contentsOf: gcURL) == before)
    }
}
