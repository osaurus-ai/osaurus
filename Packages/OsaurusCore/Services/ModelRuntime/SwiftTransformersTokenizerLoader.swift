//
//  SwiftTransformersTokenizerLoader.swift
//  osaurus
//
//  Bridges vmlx-swift's AutoTokenizer to the MLXLMCommon TokenizerLoader
//  protocol.
//

import Foundation
import MLXLMCommon
import VMLXTokenizers

struct SwiftTransformersTokenizerLoader: TokenizerLoader, @unchecked Sendable {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        let modelType = Self.modelType(in: directory)
        return TokenizerBridge(upstream: upstream, modelType: modelType)
    }

    static func normalizedToolsForChatTemplate(
        _ tools: [[String: any Sendable]]?
    ) -> [[String: any Sendable]]? {
        // Tests call this wrapper so the final Jinja-boundary schema shape is
        // pinned without exposing the private tokenizer bridge type.
        TokenizerBridge.normalizedToolsForChatTemplate(tools)
    }

    private static func modelType(in directory: URL) -> String? {
        let url = directory.appendingPathComponent("config.json")
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object["model_type"] as? String
        else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Adapts a `VMLXTokenizers.Tokenizer` to the
/// `MLXLMCommon.Tokenizer` protocol. Keep the chat-template fallback logic in
/// sync with vmlx's HuggingFace tokenizer bridge: Osaurus uses this loader in
/// production instead of the macro bridge.
private struct TokenizerBridge: MLXLMCommon.GenerationPromptControllableTokenizer, @unchecked Sendable {
    let upstream: any VMLXTokenizers.Tokenizer
    let modelType: String?

    private static let dsv4Bos =
        "<" + String(UnicodeScalar(0xFF5C)!)
        + "begin" + String(UnicodeScalar(0x2581)!) + "of"
        + String(UnicodeScalar(0x2581)!) + "sentence"
        + String(UnicodeScalar(0xFF5C)!) + ">"

    private static let dsv4Eos =
        "<" + String(UnicodeScalar(0xFF5C)!)
        + "end" + String(UnicodeScalar(0x2581)!) + "of"
        + String(UnicodeScalar(0x2581)!) + "sentence"
        + String(UnicodeScalar(0xFF5C)!) + ">"

    private static let step37Bos =
        "<" + String(UnicodeScalar(0xFF5C)!)
        + "begin" + String(UnicodeScalar(0x2581)!) + "of"
        + String(UnicodeScalar(0x2581)!) + "sentence"
        + String(UnicodeScalar(0xFF5C)!) + ">"

    private static let gemma3FunctionToolMinimal = #"""
        {{ bos_token }}
        {%- set loop_messages = messages -%}
        {%- if messages[0]['role'] == 'system' -%}
            {%- set system_message = messages[0]['content'] -%}
            {%- set loop_messages = messages[1:] -%}
        {%- else -%}
            {%- set system_message = "" -%}
        {%- endif -%}
        {%- if tools is defined and tools | length > 0 -%}
            {{ '<start_of_turn>user\n' }}
            {%- if system_message is string and system_message | length > 0 -%}
                {{ system_message | trim + '\n\n' }}
            {%- endif -%}
            {{ 'You have access to the following functions.\n' }}
            {{ 'When a function call is required, do not explain, do not summarize, and do not answer in prose.\n' }}
            {{ 'Output exactly one function call using this grammar:\n' }}
            {{ '<start_function_call>call:FUNCTION_NAME{ARGUMENT_NAME:<escape>ARGUMENT_VALUE<escape>}<end_function_call>\n' }}
            {{ 'Example:\nUser asks: Count the lines in this text: alpha\nbeta\ngamma\n' }}
            {{ 'Assistant replies: <start_function_call>call:line_count{text:<escape>alpha\nbeta\ngamma<escape>}<end_function_call>\n\n' }}
            {%- for tool in tools -%}
                {%- set fn = tool['function'] if tool['function'] is defined else tool -%}
                {{ 'Function: ' + fn['name'] + '\n' }}
                {%- if fn['description'] is defined and fn['description'] -%}
                    {{ 'Description: ' + (fn['description'] | trim) + '\n' }}
                {%- endif -%}
                {%- if fn['parameters'] is defined -%}
                    {{ 'Parameters: ' + (fn['parameters'] | tojson) + '\n' }}
                {%- endif -%}
            {%- endfor -%}
            {%- if tool_choice is defined and tool_choice == 'required' -%}
                {{ '\nThe current assistant response MUST be a function call.' }}
                {%- if tool_choice_name is defined and tool_choice_name -%}
                    {{ ' Use the `' + tool_choice_name + '` function.' }}
                {%- endif -%}
            {%- endif -%}
            {{ '<end_of_turn>\n' }}
        {%- endif -%}
        {%- for message in loop_messages -%}
            {%- set role = 'model' if message['role'] == 'assistant' else message['role'] -%}
            {%- if message['role'] == 'tool' -%}
                {{ '<start_of_turn>user\nTool result: ' + (message['content'] | string | trim) + '<end_of_turn>\n' }}
            {%- else -%}
                {{ '<start_of_turn>' + role + '\n' }}
                {%- if message['content'] is string -%}
                    {{ message['content'] | trim }}
                {%- elif message['content'] is iterable -%}
                    {%- for item in message['content'] -%}
                        {%- if item['type'] == 'text' -%}
                            {{ item['text'] | trim }}
                        {%- elif item['type'] == 'audio' -%}
                            {{ '<audio_soft_token>' }}
                        {%- elif item['type'] == 'image' -%}
                            {{ '<image_soft_token>' }}
                        {%- endif -%}
                    {%- endfor -%}
                {%- endif -%}
                {%- if message['tool_calls'] is defined and message['tool_calls'] is iterable -%}
                    {%- for tool_call in message['tool_calls'] -%}
                        {%- set fn = tool_call['function'] -%}
                        {{ '<start_function_call>call:' + fn['name'] + '{' }}
                        {%- if fn['arguments'] is mapping -%}
                            {%- set first = true -%}
                            {%- for key, value in fn['arguments'] | dictsort -%}
                                {%- if not first %},{% endif -%}
                                {%- set first = false -%}
                                {{ key + ':' }}
                                {%- if value is string -%}
                                    {{ '<escape>' + value + '<escape>' }}
                                {%- else -%}
                                    {{ value }}
                                {%- endif -%}
                            {%- endfor -%}
                        {%- elif fn['arguments'] is string -%}
                            {{ fn['arguments'] }}
                        {%- endif -%}
                        {{ '}<end_function_call>' }}
                    {%- endfor -%}
                {%- endif -%}
                {{ '<end_of_turn>\n' }}
            {%- endif -%}
        {%- endfor -%}
        {%- if add_generation_prompt -%}
            {{ '<start_of_turn>model\n' }}
        {%- endif -%}
        """#

    private enum DeepseekV4BridgeError: Error {
        case invalidRole(String)
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try applyChatTemplate(
            messages: messages,
            tools: tools,
            additionalContext: additionalContext,
            addGenerationPrompt: true
        )
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?,
        addGenerationPrompt: Bool
    ) throws -> [Int] {
        let env = ProcessInfo.processInfo.environment
        let chatTemplateTools = Self.normalizedToolsForChatTemplate(tools)
        if let path = env["VMLX_CHAT_TEMPLATE_OVERRIDE"], !path.isEmpty,
            let src = try? String(contentsOfFile: path, encoding: .utf8)
        {
            do {
                return try upstream.applyChatTemplate(
                    messages: messages,
                    chatTemplate: VMLXTokenizers.ChatTemplateArgument.literal(src),
                    addGenerationPrompt: addGenerationPrompt,
                    truncation: false,
                    maxLength: nil,
                    tools: chatTemplateTools,
                    additionalContext: additionalContext
                )
            } catch VMLXTokenizers.TokenizerError.missingChatTemplate {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
        }

        let lagunaEos =
            String(UnicodeScalar(0x3008)!)
            + "|EOS|"
            + String(UnicodeScalar(0x3009)!)
        let hasLagunaSentinel =
            upstream.bosToken == lagunaEos
            && upstream.eosToken == lagunaEos
            && upstream.convertTokenToId("<assistant>") != nil
            && upstream.convertTokenToId("</assistant>") != nil
            && upstream.convertTokenToId("<think>") != nil
            && upstream.convertTokenToId("</think>") != nil
        let normalizedModelType = modelType?.lowercased()
        let modelTypeIsGemma3n =
            normalizedModelType == "gemma3n"
            || normalizedModelType == "gemma3n_text"
        let modelTypeIsGemma3 =
            normalizedModelType == "gemma3"
            || normalizedModelType == "gemma3_text"
        let modelTypeIsZayaVL =
            normalizedModelType == "zaya1_vl"
            || normalizedModelType == "zaya_vl"
        let modelTypeIsZayaText =
            normalizedModelType == "zaya"
            || normalizedModelType == "zaya1"
        let modelTypeIsLFM2 =
            normalizedModelType == "lfm2"
            || normalizedModelType == "lfm2_moe"
            || normalizedModelType == "lfm2-vl"
            || normalizedModelType == "lfm2_vl"
        let modelTypeIsNemotron =
            normalizedModelType == "nemotron"
            || normalizedModelType == "nemotron_h"
        let hasZayaChatTokens =
            upstream.bosToken == "<bos>"
            && upstream.convertTokenToId("<|im_start|>") != nil
            && upstream.convertTokenToId("<|im_end|>") != nil
        let hasZayaVLVisionSentinel =
            hasZayaChatTokens
            && upstream.convertTokenToId("<|vision_start|>") != nil
            && upstream.convertTokenToId("<image>") != nil
            && upstream.convertTokenToId("<|vision_end|>") != nil
        let hasGemma3TurnSentinel =
            modelTypeIsGemma3
            || (normalizedModelType == nil
                && !hasZayaVLVisionSentinel
                && upstream.bosToken == "<bos>"
                && upstream.convertTokenToId("<start_of_turn>") != nil
                && upstream.convertTokenToId("<end_of_turn>") != nil)
        let hasZayaToolChatSentinel =
            (modelTypeIsZayaText || modelTypeIsZayaVL)
            && hasZayaChatTokens
            && !hasGemma3TurnSentinel
        let hasDSV4Sentinel =
            !hasZayaVLVisionSentinel
            && upstream.bosToken == Self.dsv4Bos
        let hasStep37Sentinels =
            upstream.bosToken == Self.step37Bos
            && upstream.eosToken == "<|im_end|>"
            && upstream.convertTokenToId("<|im_start|>") != nil
            && upstream.convertTokenToId("<tool_call>") != nil
            && upstream.convertTokenToId("<im_patch>") != nil
        if hasLagunaSentinel
            && (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1"
        {
            return try fallback(
                label: "LagunaMinimal",
                template: MLXLMCommon.ChatTemplateFallbacks.lagunaMinimal,
                messages: messages,
                tools: chatTemplateTools,
                additionalContext: additionalContext,
                addGenerationPrompt: addGenerationPrompt
            )
        }

        if let ctx = additionalContext,
            let enableThinking = ctx["enable_thinking"] as? Bool,
            enableThinking == false,
            upstream.bosToken == "]~!b[",
            upstream.eosToken == "[e~["
        {
            do {
                return try fallback(
                    label: "MiniMaxM2Minimal",
                    template: MLXLMCommon.ChatTemplateFallbacks.minimaxM2Minimal,
                    messages: messages,
                    tools: chatTemplateTools,
                    additionalContext: additionalContext,
                    addGenerationPrompt: addGenerationPrompt
                )
            } catch {
                // Fall through to native template if the corrected template
                // trips a Jinja runtime issue.
            }
        }

        var adjustedContext = additionalContext
        if modelTypeIsLFM2,
            !(chatTemplateTools?.isEmpty ?? true),
            (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1"
        {
            return try fallback(
                label: "LFM2ToolMinimal",
                template: MLXLMCommon.ChatTemplateFallbacks.lfm2ToolMinimal,
                messages: messages,
                tools: chatTemplateTools,
                additionalContext: adjustedContext,
                addGenerationPrompt: addGenerationPrompt
            )
        }
        if hasStep37Sentinels,
            (!(chatTemplateTools?.isEmpty ?? true)
                || (adjustedContext?["enable_thinking"] as? Bool) == false),
            (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1"
        {
            return try fallback(
                label: "Step37Minimal",
                template: MLXLMCommon.ChatTemplateFallbacks.step37Minimal,
                messages: messages,
                tools: chatTemplateTools,
                additionalContext: adjustedContext,
                addGenerationPrompt: addGenerationPrompt
            )
        }
        if hasZayaToolChatSentinel,
            (Self.messagesContainImageContent(messages) || !(chatTemplateTools?.isEmpty ?? true)),
            (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1"
        {
            return try fallback(
                label: "Zaya1VLVisionToolMinimal",
                template: MLXLMCommon.ChatTemplateFallbacks.zayaVLVisionToolMinimal,
                messages: messages,
                tools: chatTemplateTools,
                additionalContext: adjustedContext,
                addGenerationPrompt: addGenerationPrompt
            )
        }
        if adjustedContext?["reasoning_effort"] == nil,
            upstream.convertTokenToId("[MODEL_SETTINGS]") != nil,
            let enableThinking = adjustedContext?["enable_thinking"] as? Bool
        {
            var ctx = adjustedContext ?? [:]
            ctx["reasoning_effort"] = enableThinking ? "high" : "none"
            adjustedContext = ctx
        }
        if hasDSV4Sentinel,
            let enableThinking = adjustedContext?["enable_thinking"] as? Bool,
            enableThinking == false,
            adjustedContext?["reasoning_effort"] != nil
        {
            adjustedContext?.removeValue(forKey: "reasoning_effort")
        }
        if hasDSV4Sentinel {
            return try applyDeepseekV4NativeTemplate(
                messages: messages,
                tools: chatTemplateTools,
                additionalContext: adjustedContext,
                addGenerationPrompt: addGenerationPrompt
            )
        }
        // Mistral 3.x packs (e.g. mlx-community Mistral-Small-3.1/3.2) ship only
        // the HF vision chat_template ([SYSTEM_PROMPT]/[INST]/[IMG], no tools) or
        // a bare tokenizer, so the bridge otherwise prompts without
        // [AVAILABLE_TOOLS] (tools never ground -> the model emits a foreign
        // ChatML/Hermes format) and may mis-route to a ChatML fallback. Apply the
        // complete native Mistral template so reasoning / tools / vision all work
        // natively. Detected by Mistral's tekken special tokens, not by name.
        //
        // `convertTokenToId` is NOT a reliable presence test: BPE/Unigram
        // tokenizers return the unknown-token id for any absent token (see
        // BPETokenizer `tokensToIds[token] ?? unknownTokenId`), so `!= nil` is
        // true for every string on a tokenizer that declares an <unk> (e.g. a
        // Gemma SentencePiece pack). Require each tekken token to round-trip —
        // `convertIdToToken(convertTokenToId(t)) == t` — which only holds when
        // the token genuinely exists in the vocab (unk-mapped strings decode
        // back to "<unk>", not to themselves).
        func hasExactToken(_ token: String) -> Bool {
            guard let id = upstream.convertTokenToId(token),
                upstream.convertIdToToken(id) == token
            else { return false }
            return true
        }
        let hasMistralSentinel =
            hasExactToken("[INST]")
            && hasExactToken("[SYSTEM_PROMPT]")
            && hasExactToken("[AVAILABLE_TOOLS]")
            && hasExactToken("[TOOL_CALLS]")
        if hasMistralSentinel,
            (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1"
        {
            return try fallback(
                label: "Mistral3CompleteMinimal",
                template: MLXLMCommon.ChatTemplateFallbacks.mistral3CompleteMinimal,
                messages: messages,
                tools: chatTemplateTools,
                additionalContext: adjustedContext,
                addGenerationPrompt: addGenerationPrompt
            )
        }
        if modelTypeIsNemotron,
            !(chatTemplateTools?.isEmpty ?? true),
            (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1"
        {
            let fallbackMessages =
                Self.requiresToolChoice(adjustedContext)
                ? Self.compactCompletedToolHistoryForRequiredChoice(messages)
                : messages
            return try fallback(
                label: "NemotronMinimal",
                template: MLXLMCommon.ChatTemplateFallbacks.nemotronMinimal,
                messages: fallbackMessages,
                tools: chatTemplateTools,
                additionalContext: adjustedContext,
                addGenerationPrompt: addGenerationPrompt
            )
        }
        if hasGemma3TurnSentinel,
            !(chatTemplateTools?.isEmpty ?? true),
            (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1"
        {
            return try fallback(
                label: "Gemma3FunctionToolMinimal",
                template: Self.gemma3FunctionToolMinimal,
                messages: messages,
                tools: chatTemplateTools,
                additionalContext: adjustedContext,
                addGenerationPrompt: addGenerationPrompt
            )
        }
        if !(chatTemplateTools?.isEmpty ?? true),
            upstream.bosToken == "<s>",
            upstream.convertTokenToId("<|im_end|>") != nil,
            (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1"
        {
            return try fallback(
                label: "NemotronMinimal",
                template: MLXLMCommon.ChatTemplateFallbacks.nemotronMinimal,
                messages: messages,
                tools: chatTemplateTools,
                additionalContext: adjustedContext,
                addGenerationPrompt: addGenerationPrompt
            )
        }
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                chatTemplate: nil,
                addGenerationPrompt: addGenerationPrompt,
                truncation: false,
                maxLength: nil,
                tools: chatTemplateTools,
                additionalContext: adjustedContext
            )
        } catch VMLXTokenizers.TokenizerError.missingChatTemplate {
            guard (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1" else {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
            if hasLagunaSentinel {
                return try fallback(
                    label: "LagunaMinimal",
                    template: MLXLMCommon.ChatTemplateFallbacks.lagunaMinimal,
                    messages: messages,
                    tools: chatTemplateTools,
                    additionalContext: adjustedContext,
                    addGenerationPrompt: addGenerationPrompt
                )
            }
            if upstream.bosToken == "]~!b[",
                upstream.eosToken == "[e~["
            {
                return try fallback(
                    label: "MiniMaxM2Minimal",
                    template: MLXLMCommon.ChatTemplateFallbacks.minimaxM2Minimal,
                    messages: messages,
                    tools: chatTemplateTools,
                    additionalContext: additionalContext,
                    addGenerationPrompt: addGenerationPrompt
                )
            }
            if hasZayaToolChatSentinel,
                Self.messagesContainImageContent(messages) || !(chatTemplateTools?.isEmpty ?? true)
            {
                return try fallback(
                    label: "Zaya1VLVisionToolMinimal",
                    template: MLXLMCommon.ChatTemplateFallbacks.zayaVLVisionToolMinimal,
                    messages: messages,
                    tools: chatTemplateTools,
                    additionalContext: adjustedContext,
                    addGenerationPrompt: addGenerationPrompt
                )
            }
            if hasGemma3TurnSentinel,
                !(chatTemplateTools?.isEmpty ?? true)
            {
                return try fallback(
                    label: "Gemma3FunctionToolMinimal",
                    template: Self.gemma3FunctionToolMinimal,
                    messages: messages,
                    tools: chatTemplateTools,
                    additionalContext: adjustedContext,
                    addGenerationPrompt: addGenerationPrompt
                )
            }
            if upstream.bosToken == "<bos>" {
                let template =
                    (chatTemplateTools?.isEmpty ?? true) || modelTypeIsGemma3n
                    ? MLXLMCommon.ChatTemplateFallbacks.gemma4Minimal
                    : MLXLMCommon.ChatTemplateFallbacks.gemma4WithTools
                let fallbackMessages =
                    Self.requiresToolChoice(adjustedContext)
                    ? Self.compactCompletedToolHistoryForRequiredChoice(messages)
                    : messages
                let fallbackTools = modelTypeIsGemma3n ? nil : chatTemplateTools
                return try fallback(
                    label: "Gemma4",
                    template: template,
                    messages: fallbackMessages,
                    tools: fallbackTools,
                    additionalContext: adjustedContext,
                    addGenerationPrompt: addGenerationPrompt
                )
            }
            if upstream.bosToken == "<s>",
                upstream.convertTokenToId("<|im_end|>") != nil
            {
                return try fallback(
                    label: "NemotronMinimal",
                    template: MLXLMCommon.ChatTemplateFallbacks.nemotronMinimal,
                    messages: messages,
                    tools: chatTemplateTools,
                    additionalContext: additionalContext,
                    addGenerationPrompt: addGenerationPrompt
                )
            }
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        } catch {
            guard (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1" else {
                throw error
            }
            let isGemma = upstream.bosToken == "<bos>" && !hasZayaToolChatSentinel
            let hasNemotronSentinel =
                upstream.convertTokenToId("<|im_start|>") != nil
                || upstream.convertTokenToId("<|im_end|>") != nil
            if isGemma {
                throw error
            }
            let ordered: [(label: String, template: String)]
            if hasLagunaSentinel {
                ordered = [("LagunaMinimal", MLXLMCommon.ChatTemplateFallbacks.lagunaMinimal)]
            } else if hasZayaToolChatSentinel,
                Self.messagesContainImageContent(messages) || !(chatTemplateTools?.isEmpty ?? true)
            {
                ordered = [
                    (
                        "Zaya1VLVisionToolMinimal",
                        MLXLMCommon.ChatTemplateFallbacks.zayaVLVisionToolMinimal
                    )
                ]
            } else if hasNemotronSentinel {
                ordered = [
                    ("NemotronMinimal", MLXLMCommon.ChatTemplateFallbacks.nemotronMinimal)
                ]
            } else {
                ordered = MLXLMCommon.ChatTemplateFallbacks.orderedFallbacks
            }
            for candidate in ordered {
                do {
                    return try fallback(
                        label: candidate.label,
                        template: candidate.template,
                        messages: messages,
                        tools: chatTemplateTools,
                        additionalContext: adjustedContext,
                        addGenerationPrompt: addGenerationPrompt
                    )
                } catch {
                    continue
                }
            }
            throw error
        }
    }

    private static func messagesContainImageContent(_ messages: [[String: any Sendable]]) -> Bool {
        messages.contains { message in
            contentContainsImage(message["content"])
        }
    }

    private static func requiresToolChoice(_ context: [String: any Sendable]?) -> Bool {
        guard let context else { return false }
        if (context["tool_choice"] as? String) == "required" {
            return true
        }
        if let name = context["tool_choice_name"] as? String,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        return false
    }

    private static func compactCompletedToolHistoryForRequiredChoice(
        _ messages: [[String: any Sendable]]
    ) -> [[String: any Sendable]] {
        guard
            let latestUserIndex = messages.lastIndex(where: {
                let role = $0["role"] as? String
                return role == "user" || role == "developer"
            })
        else {
            return messages
        }

        var compacted: [[String: any Sendable]] = []
        compacted.reserveCapacity(messages.count)

        for (index, message) in messages.enumerated() {
            if index >= latestUserIndex {
                compacted.append(message)
                continue
            }

            let role = message["role"] as? String
            if role == "system" || role == "developer" {
                compacted.append(message)
            }
        }

        return compacted
    }

    private static func messageContentString(_ content: Any?) -> String {
        if let string = content as? String {
            return string
        }
        if let parts = content as? [[String: any Sendable]] {
            return parts.compactMap { part in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }.joined(separator: "\n")
        }
        if let parts = content as? [[String: String]] {
            return parts.compactMap { part in
                guard part["type"] == "text" else { return nil }
                return part["text"]
            }.joined(separator: "\n")
        }
        return ""
    }

    static func normalizedToolsForChatTemplate(
        _ tools: [[String: any Sendable]]?
    ) -> [[String: any Sendable]]? {
        tools?.map { normalizeChatTemplateTool($0) }
    }

    private static func normalizeChatTemplateTool(
        _ tool: [String: any Sendable]
    ) -> [String: any Sendable] {
        // Some callers already came through `Tool.toTokenizerToolSpec`, while
        // plugin/host dictionaries can arrive pre-shaped. Normalize again at
        // the Jinja boundary so Gemma-style string filters never see booleans
        // or array-valued schema types.
        var normalized = tool
        guard var function = normalized["function"] as? [String: any Sendable] else {
            return normalized
        }

        if let parameters = function["parameters"] {
            function["parameters"] = normalizeChatTemplateSchemaValue(
                parameters,
                inSchemaPosition: true
            )
        }
        if let response = function["response"] {
            function["response"] = normalizeChatTemplateSchemaValue(
                response,
                inSchemaPosition: true
            )
        }
        normalized["function"] = function
        return normalized
    }

    private static func normalizeChatTemplateSchemaValue(
        _ value: any Sendable,
        inSchemaPosition: Bool
    ) -> any Sendable {
        if let object = value as? [String: any Sendable] {
            var normalized: [String: any Sendable] = [:]
            normalized.reserveCapacity(object.count)

            for (key, child) in object {
                switch key {
                case "properties":
                    if let properties = child as? [String: any Sendable] {
                        var normalizedProperties: [String: any Sendable] = [:]
                        normalizedProperties.reserveCapacity(properties.count)
                        for (propertyName, propertySchema) in properties {
                            normalizedProperties[propertyName] = normalizeChatTemplateSchemaValue(
                                propertySchema,
                                inSchemaPosition: true
                            )
                        }
                        normalized[key] = normalizedProperties
                    } else {
                        normalized[key] = normalizeChatTemplateSchemaValue(
                            child,
                            inSchemaPosition: false
                        )
                    }
                case "items", "response":
                    normalized[key] = normalizeChatTemplateSchemaValue(
                        child,
                        inSchemaPosition: true
                    )
                case "additionalProperties":
                    if isJSONBoolean(child) { continue }
                    normalized[key] = normalizeChatTemplateSchemaValue(
                        child,
                        inSchemaPosition: true
                    )
                case "oneOf", "anyOf", "allOf":
                    if let branches = child as? [any Sendable] {
                        normalized[key] =
                            branches.map {
                                normalizeChatTemplateSchemaValue(
                                    $0,
                                    inSchemaPosition: true
                                )
                            } as [any Sendable]
                    } else {
                        normalized[key] = normalizeChatTemplateSchemaValue(
                            child,
                            inSchemaPosition: false
                        )
                    }
                default:
                    normalized[key] = normalizeChatTemplateSchemaValue(
                        child,
                        inSchemaPosition: false
                    )
                }
            }

            if inSchemaPosition {
                normalizeTemplateRenderableSchemaType(&normalized)
            }
            return normalized
        }

        if let array = value as? [any Sendable] {
            return array.map {
                normalizeChatTemplateSchemaValue($0, inSchemaPosition: inSchemaPosition)
            } as [any Sendable]
        }

        if inSchemaPosition, isJSONBoolean(value) {
            return ["type": "string"] as [String: any Sendable]
        }

        return value
    }

    private static func normalizeTemplateRenderableSchemaType(_ object: inout [String: any Sendable]) {
        guard let typeValue = object["type"] else {
            object["type"] = inferredFallbackType(for: object)
            return
        }

        if typeValue is String { return }
        if let entries = stringTypeArray(typeValue) {
            normalizeTypeUnion(entries, in: &object)
            return
        }
        object["type"] = inferredFallbackType(for: object)
    }

    private static func normalizeTypeUnion(
        _ entries: [String],
        in object: inout [String: any Sendable]
    ) {
        var hasNull = false
        var scalarTypes: [String] = []
        for entry in entries {
            if entry == "null" {
                hasNull = true
            } else if !scalarTypes.contains(entry) {
                scalarTypes.append(entry)
            }
        }

        object["type"] = scalarTypes.first ?? "string"
        if hasNull {
            object["nullable"] = true
        }
    }

    private static func inferredFallbackType(for object: [String: any Sendable]) -> String {
        if object["properties"] != nil { return "object" }
        if object["items"] != nil { return "array" }
        return "string"
    }

    private static func stringTypeArray(_ value: (any Sendable)?) -> [String]? {
        if let strings = value as? [String] {
            return strings
        }

        if let entries = value as? [any Sendable] {
            var strings: [String] = []
            for entry in entries {
                guard let string = entry as? String else { return nil }
                strings.append(string)
            }
            return strings
        }

        return nil
    }

    private static func isJSONBoolean(_ value: Any) -> Bool {
        if value is Bool { return true }
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func contentContainsImage(_ content: Any?) -> Bool {
        guard let content else { return false }
        if let blocks = content as? [[String: any Sendable]] {
            return blocks.contains { ($0["type"] as? String) == "image" }
        }
        if let blocks = content as? [[String: String]] {
            return blocks.contains { $0["type"] == "image" }
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.contains { ($0["type"] as? String) == "image" }
        }
        if let blocks = content as? [any Sendable] {
            return blocks.contains { contentContainsImage($0) }
        }
        if let blocks = content as? [Any] {
            return blocks.contains { contentContainsImage($0) }
        }
        return false
    }

    private static func deepseekV4Role(
        from rawRole: String
    ) throws -> MLXLMCommon.DeepseekV4ChatEncoder.MessageRole {
        switch rawRole {
        case "system": return .system
        case "developer": return .developer
        case "user": return .user
        case "assistant": return .assistant
        case "tool": return .tool
        case "latest_reminder": return .latestReminder
        default: throw DeepseekV4BridgeError.invalidRole(rawRole)
        }
    }

    private static func deepseekV4String(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let blocks = value as? [[String: any Sendable]] {
            let text = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                if let content = block["content"] as? String { return content }
                return nil
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        if let blocks = value as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                if let content = block["content"] as? String { return content }
                return nil
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return String(describing: value)
    }

    private static func deepseekV4JSONObject(_ value: Any) -> Any {
        switch value {
        case let value as String:
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Int64:
            return value
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as NSNull:
            return value
        case let value as [String: any Sendable]:
            return value.mapValues { deepseekV4JSONObject($0) }
        case let value as [String: Any]:
            return value.mapValues { deepseekV4JSONObject($0) }
        case let value as [any Sendable]:
            return value.map { deepseekV4JSONObject($0) }
        case let value as [Any]:
            return value.map { deepseekV4JSONObject($0) }
        default:
            return String(describing: value)
        }
    }

    private static func deepseekV4JSONString(_ value: Any?) -> String {
        guard let value else { return "{}" }
        if let string = value as? String { return string }
        let json = deepseekV4JSONObject(value)
        guard JSONSerialization.isValidJSONObject(json),
            let data = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.withoutEscapingSlashes, .sortedKeys]
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func deepseekV4ToolCalls(
        from rawToolCalls: Any?
    ) -> [MLXLMCommon.DeepseekV4ChatEncoder.ToolCall]? {
        guard let rawToolCalls else { return nil }
        let rawCalls: [[String: any Sendable]]
        if let calls = rawToolCalls as? [[String: any Sendable]] {
            rawCalls = calls
        } else {
            return nil
        }

        let converted = rawCalls.compactMap {
            call -> MLXLMCommon.DeepseekV4ChatEncoder.ToolCall? in
            let function = call["function"] as? [String: any Sendable]
            let id = deepseekV4String(call["id"])
            guard
                let name = deepseekV4String(call["name"])
                    ?? deepseekV4String(function?["name"])
            else {
                return nil
            }
            let arguments = deepseekV4JSONString(call["arguments"] ?? function?["arguments"])
            return MLXLMCommon.DeepseekV4ChatEncoder.ToolCall(
                id: id,
                name: name,
                arguments: arguments
            )
        }
        return converted.isEmpty ? nil : converted
    }

    private func applyDeepseekV4NativeTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?,
        addGenerationPrompt: Bool
    ) throws -> [Int] {
        var dsv4Messages = try messages.map { raw -> MLXLMCommon.DeepseekV4ChatEncoder.Message in
            let role = try Self.deepseekV4Role(
                from: Self.deepseekV4String(raw["role"]) ?? "user"
            )
            return MLXLMCommon.DeepseekV4ChatEncoder.Message(
                role: role,
                content: Self.deepseekV4String(raw["content"]),
                reasoningContent: Self.deepseekV4String(raw["reasoning_content"]),
                toolCalls: Self.deepseekV4ToolCalls(from: raw["tool_calls"]),
                toolCallId: Self.deepseekV4String(raw["tool_call_id"]),
                responseFormat: raw["response_format"] as? [String: any Sendable],
                task: Self.deepseekV4String(raw["task"])
            )
        }
        let toolChoiceRequired =
            Self.deepseekV4String(additionalContext?["tool_choice"]) == "required"
        let toolChoiceName = Self.deepseekV4String(additionalContext?["tool_choice_name"])
        if toolChoiceRequired || !(toolChoiceName?.isEmpty ?? true) {
            dsv4Messages = Self.compactCompletedDSV4ToolHistory(dsv4Messages)
        }

        if let tools, !tools.isEmpty {
            if let idx = dsv4Messages.firstIndex(where: {
                $0.role == .system || $0.role == .developer
            }) {
                dsv4Messages[idx].tools = tools
            } else {
                dsv4Messages.insert(
                    MLXLMCommon.DeepseekV4ChatEncoder.Message(
                        role: .system,
                        content: "",
                        tools: tools
                    ),
                    at: 0
                )
            }
        }

        if let responseFormat = additionalContext?["response_format"] as? [String: any Sendable] {
            if let idx = dsv4Messages.firstIndex(where: {
                $0.role == .system || $0.role == .developer
            }) {
                dsv4Messages[idx].responseFormat = responseFormat
            } else {
                dsv4Messages.insert(
                    MLXLMCommon.DeepseekV4ChatEncoder.Message(
                        role: .system,
                        content: "",
                        responseFormat: responseFormat
                    ),
                    at: 0
                )
            }
        }

        let enableThinking = additionalContext?["enable_thinking"] as? Bool
        let thinkingMode: MLXLMCommon.DeepseekV4ThinkingMode =
            enableThinking == true ? .thinking : .chat

        let effort: MLXLMCommon.DeepseekV4ReasoningEffort?
        if thinkingMode == .thinking {
            switch Self.deepseekV4String(additionalContext?["reasoning_effort"]) {
            case "max": effort = .max
            case "high": effort = .high
            default: effort = nil
            }
        } else {
            effort = nil
        }

        var prompt = MLXLMCommon.DeepseekV4ChatEncoder().encode(
            messages: dsv4Messages,
            thinkingMode: thinkingMode,
            reasoningEffort: effort,
            dropEarlierReasoning: true,
            toolChoiceRequired: toolChoiceRequired,
            toolChoiceName: toolChoiceName
        )
        if !addGenerationPrompt,
            let lastRole = dsv4Messages.last?.role,
            lastRole == .user || lastRole == .developer
        {
            let tail =
                MLXLMCommon.DeepseekV4Tokens.assistant
                + (thinkingMode == .thinking
                    ? MLXLMCommon.DeepseekV4Tokens.thinkStart
                    : MLXLMCommon.DeepseekV4Tokens.thinkEnd)
            if prompt.hasSuffix(tail) {
                prompt.removeLast(tail.count)
            }
        }
        return upstream.encode(text: prompt, addSpecialTokens: false)
    }

    private static func compactCompletedDSV4ToolHistory(
        _ messages: [MLXLMCommon.DeepseekV4ChatEncoder.Message]
    ) -> [MLXLMCommon.DeepseekV4ChatEncoder.Message] {
        guard
            let latestUserIndex = messages.lastIndex(where: {
                $0.role == .user || $0.role == .developer
            })
        else {
            return messages
        }

        let hasLaterAssistantAnswerBeforeLatestUser: (Int) -> Bool = { index in
            guard index + 1 < latestUserIndex else { return false }
            return messages[(index + 1) ..< latestUserIndex].contains { message in
                guard message.role == .assistant else { return false }
                if let content = message.content,
                    !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return true
                }
                if let reasoning = message.reasoningContent,
                    !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return true
                }
                return false
            }
        }

        var compacted: [MLXLMCommon.DeepseekV4ChatEncoder.Message] = []
        compacted.reserveCapacity(messages.count)
        var droppingClosedToolResult = false

        for (index, message) in messages.enumerated() {
            if index >= latestUserIndex {
                compacted.append(message)
                continue
            }

            if message.role == .assistant,
                let toolCalls = message.toolCalls,
                !toolCalls.isEmpty,
                hasLaterAssistantAnswerBeforeLatestUser(index)
            {
                droppingClosedToolResult = true
                let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let reasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !content.isEmpty || !reasoning.isEmpty else {
                    continue
                }
                var copy = message
                copy.toolCalls = nil
                compacted.append(copy)
                continue
            }

            if message.role == .tool, droppingClosedToolResult {
                continue
            }

            if message.role != .tool {
                droppingClosedToolResult = false
            }
            compacted.append(message)
        }

        return compacted
    }

    private func fallback(
        label: String,
        template: String,
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?,
        addGenerationPrompt: Bool
    ) throws -> [Int] {
        if (ProcessInfo.processInfo.environment["VMLX_CHAT_TEMPLATE_FALLBACK_LOG"] ?? "0") == "1" {
            FileHandle.standardError.write(
                "[osaurus] chat-template fallback engaged: \(label)\n"
                    .data(using: .utf8)!
            )
        }
        return try upstream.applyChatTemplate(
            messages: messages,
            chatTemplate: VMLXTokenizers.ChatTemplateArgument.literal(template),
            addGenerationPrompt: addGenerationPrompt,
            truncation: false,
            maxLength: nil,
            tools: tools,
            additionalContext: additionalContext
        )
    }
}
