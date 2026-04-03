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
/// `MLXLMCommon.Tokenizer` protocol. The two protocols have nearly identical
/// signatures; the main difference is `decode(tokens:)` vs `decode(tokenIds:)`.
private struct TokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let upstream: any Tokenizers.Tokenizer

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
        try upstream.applyChatTemplate(
            messages: messages,
            tools: tools,
            additionalContext: additionalContext
        )
    }
}
