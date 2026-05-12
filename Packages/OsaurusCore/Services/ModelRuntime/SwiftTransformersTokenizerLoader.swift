//
//  SwiftTransformersTokenizerLoader.swift
//  osaurus
//
//  Bridges the swift-transformers AutoTokenizer to the MLXLMCommon
//  TokenizerLoader protocol introduced in mlx-swift-lm 3.x.
//

import Foundation
import MLXLMCommon
import Tokenizers

struct SwiftTransformersTokenizerLoader: TokenizerLoader, @unchecked Sendable {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream: upstream)
    }
}

/// Adapts a `Tokenizers.Tokenizer` (from swift-transformers) to the
/// `MLXLMCommon.Tokenizer` protocol. Keep the chat-template fallback logic in
/// sync with vmlx's HuggingFace tokenizer bridge: Osaurus uses this loader in
/// production instead of the macro bridge.
private struct TokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let upstream: any Tokenizers.Tokenizer

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
        let env = ProcessInfo.processInfo.environment
        if let path = env["VMLX_CHAT_TEMPLATE_OVERRIDE"], !path.isEmpty,
            let src = try? String(contentsOfFile: path, encoding: .utf8)
        {
            do {
                return try upstream.applyChatTemplate(
                    messages: messages,
                    chatTemplate: Tokenizers.ChatTemplateArgument.literal(src),
                    addGenerationPrompt: true,
                    truncation: false,
                    maxLength: nil,
                    tools: tools,
                    additionalContext: additionalContext
                )
            } catch Tokenizers.TokenizerError.missingChatTemplate {
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
        let hasDSV4Sentinel =
            upstream.bosToken == Self.dsv4Bos
            || (upstream.convertTokenToId(Self.dsv4Bos) != nil
                && upstream.convertTokenToId(Self.dsv4Eos) != nil)
        if hasLagunaSentinel
            && (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1"
        {
            return try fallback(
                label: "LagunaMinimal",
                template: MLXLMCommon.ChatTemplateFallbacks.lagunaMinimal,
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
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
                    additionalContext: additionalContext
                )
            } catch {
                // Fall through to native template if the corrected template
                // trips a Jinja runtime issue.
            }
        }

        var adjustedContext = additionalContext
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

        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: adjustedContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            guard (env["VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE"] ?? "0") != "1" else {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
            if hasLagunaSentinel {
                return try fallback(
                    label: "LagunaMinimal",
                    template: MLXLMCommon.ChatTemplateFallbacks.lagunaMinimal,
                    messages: messages,
                    tools: tools,
                    additionalContext: adjustedContext
                )
            }
            if hasDSV4Sentinel {
                return try fallback(
                    label: "DSV4Minimal",
                    template: MLXLMCommon.ChatTemplateFallbacks.dsv4Minimal,
                    messages: messages,
                    tools: tools,
                    additionalContext: adjustedContext
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
                    additionalContext: additionalContext
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
                    additionalContext: additionalContext
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
                    additionalContext: additionalContext
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
            } else if hasDSV4Sentinel {
                ordered = [("DSV4Minimal", MLXLMCommon.ChatTemplateFallbacks.dsv4Minimal)]
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
                        additionalContext: adjustedContext
                    )
                } catch {
                    continue
                }
            }
            throw error
        }
    }

    private func fallback(
        label: String,
        template: String,
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        if (ProcessInfo.processInfo.environment["VMLX_CHAT_TEMPLATE_FALLBACK_LOG"] ?? "0") == "1" {
            FileHandle.standardError.write(
                "[osaurus] chat-template fallback engaged: \(label)\n"
                    .data(using: .utf8)!
            )
        }
        return try upstream.applyChatTemplate(
            messages: messages,
            chatTemplate: Tokenizers.ChatTemplateArgument.literal(template),
            addGenerationPrompt: true,
            truncation: false,
            maxLength: nil,
            tools: tools,
            additionalContext: additionalContext
        )
    }
}
