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
}
