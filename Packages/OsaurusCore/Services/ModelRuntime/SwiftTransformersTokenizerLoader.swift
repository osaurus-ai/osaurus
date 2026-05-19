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
        return TokenizerBridge(upstream: upstream)
    }
}

/// Adapts a `VMLXTokenizers.Tokenizer` to the
/// `MLXLMCommon.Tokenizer` protocol. Keep the chat-template fallback logic in
/// sync with vmlx's HuggingFace tokenizer bridge: Osaurus uses this loader in
/// production instead of the macro bridge.
private struct TokenizerBridge: MLXLMCommon.GenerationPromptControllableTokenizer, @unchecked Sendable {
    let upstream: any VMLXTokenizers.Tokenizer

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
                    tools: tools,
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
        let hasZayaVLVisionSentinel =
            upstream.bosToken == "<bos>"
            && upstream.convertTokenToId("<|vision_start|>") != nil
            && upstream.convertTokenToId("<image>") != nil
            && upstream.convertTokenToId("<|vision_end|>") != nil
            && upstream.convertTokenToId("<|im_start|>") != nil
            && upstream.convertTokenToId("<|im_end|>") != nil
        let hasDSV4Sentinel =
            !hasZayaVLVisionSentinel
            && (upstream.bosToken == Self.dsv4Bos
                || (upstream.convertTokenToId(Self.dsv4Bos) != nil
                && upstream.convertTokenToId(Self.dsv4Eos) != nil)
            )
        if hasLagunaSentinel
            && (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1"
        {
            return try fallback(
                label: "LagunaMinimal",
                template: MLXLMCommon.ChatTemplateFallbacks.lagunaMinimal,
                messages: messages,
                tools: tools,
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
                    tools: tools,
                    additionalContext: additionalContext,
                    addGenerationPrompt: addGenerationPrompt
                )
            } catch {
                // Fall through to native template if the corrected template
                // trips a Jinja runtime issue.
            }
        }

        var adjustedContext = additionalContext
        if hasZayaVLVisionSentinel,
            Self.messagesContainImageContent(messages),
            (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1"
        {
            return try fallback(
                label: "Zaya1VLVisionToolMinimal",
                template: MLXLMCommon.ChatTemplateFallbacks.zayaVLVisionToolMinimal,
                messages: messages,
                tools: tools,
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
                tools: tools,
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
                tools: tools,
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
                    tools: tools,
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
                    tools: tools,
                    additionalContext: additionalContext,
                    addGenerationPrompt: addGenerationPrompt
                )
            }
            if hasZayaVLVisionSentinel, Self.messagesContainImageContent(messages) {
                return try fallback(
                    label: "Zaya1VLVisionToolMinimal",
                    template: MLXLMCommon.ChatTemplateFallbacks.zayaVLVisionToolMinimal,
                    messages: messages,
                    tools: tools,
                    additionalContext: adjustedContext,
                    addGenerationPrompt: addGenerationPrompt
                )
            }
            if upstream.bosToken == "<bos>" {
                let template =
                    (tools?.isEmpty ?? true)
                    ? MLXLMCommon.ChatTemplateFallbacks.gemma4Minimal
                    : MLXLMCommon.ChatTemplateFallbacks.gemma4WithTools
                return try fallback(
                    label: "Gemma4",
                    template: template,
                    messages: messages,
                    tools: tools,
                    additionalContext: additionalContext,
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
                    tools: tools,
                    additionalContext: additionalContext,
                    addGenerationPrompt: addGenerationPrompt
                )
            }
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        } catch {
            guard (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1" else {
                throw error
            }
            let isGemma = upstream.bosToken == "<bos>"
            let hasNemotronSentinel =
                upstream.convertTokenToId("<|im_start|>") != nil
                || upstream.convertTokenToId("<|im_end|>") != nil
            let ordered: [(label: String, template: String)]
            if hasLagunaSentinel {
                ordered = [("LagunaMinimal", MLXLMCommon.ChatTemplateFallbacks.lagunaMinimal)]
            } else if hasZayaVLVisionSentinel, Self.messagesContainImageContent(messages) {
                ordered = [
                    (
                        "Zaya1VLVisionToolMinimal",
                        MLXLMCommon.ChatTemplateFallbacks.zayaVLVisionToolMinimal
                    )
                ]
            } else if isGemma {
                ordered = [
                    ("Gemma4WithTools", MLXLMCommon.ChatTemplateFallbacks.gemma4WithTools),
                    ("Gemma4Minimal", MLXLMCommon.ChatTemplateFallbacks.gemma4Minimal),
                ]
            } else if hasNemotronSentinel {
                ordered = [
                    ("NemotronMinimal", MLXLMCommon.ChatTemplateFallbacks.nemotronMinimal),
                    ("Gemma4WithTools", MLXLMCommon.ChatTemplateFallbacks.gemma4WithTools),
                    ("Gemma4Minimal", MLXLMCommon.ChatTemplateFallbacks.gemma4Minimal),
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
                        tools: tools,
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
            guard let name = deepseekV4String(call["name"])
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
            dropEarlierReasoning: true
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
