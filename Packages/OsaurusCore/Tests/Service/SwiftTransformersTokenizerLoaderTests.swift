//
//  SwiftTransformersTokenizerLoaderTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SwiftTransformersTokenizerLoaderTests {
    @Test func dsv4LocalTokenizerUsesVmlxFallback() async throws {
        let defaultPath = "/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_DSV4_TEST_MODEL"] ?? defaultPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard FileManager.default.fileExists(
            atPath: modelURL.appendingPathComponent("tokenizer.json").path
        ) else {
            return
        }

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: modelURL)
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": "Say ok."]],
            tools: nil,
            additionalContext: ["enable_thinking": false]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(
            decoded.hasPrefix("<\u{FF5C}begin\u{2581}of\u{2581}sentence\u{FF5C}>"),
            "DSV4 bundles have no tokenizer chat_template; Osaurus must route through vmlx's DSV4 fallback. Decoded: \(decoded)"
        )
        #expect(
            decoded.hasSuffix("<\u{FF5C}Assistant\u{FF5C}></think>"),
            "DSV4 instruct mode must close the reasoning tag in the prompt tail. Decoded: \(decoded)"
        )

        let multiTurnTokenIds = try tokenizer.applyChatTemplate(
            messages: [
                ["role": "user", "content": "Turn 1."],
                ["role": "assistant", "content": "Answer 1."],
                ["role": "user", "content": "Turn 2."],
            ],
            tools: nil,
            additionalContext: ["enable_thinking": false]
        )
        let multiTurnDecoded = tokenizer.decode(
            tokenIds: multiTurnTokenIds,
            skipSpecialTokens: false
        )
        #expect(
            multiTurnDecoded.contains(
                "<\u{FF5C}User\u{FF5C}>Turn 1.<\u{FF5C}Assistant\u{FF5C}></think>Answer 1.<\u{FF5C}end\u{2581}of\u{2581}sentence\u{FF5C}>"
            ),
            "DSV4 prior assistant turns must include the canonical closed-thinking transition. Decoded: \(multiTurnDecoded)"
        )
        #expect(
            multiTurnDecoded.hasSuffix(
                "<\u{FF5C}User\u{FF5C}>Turn 2.<\u{FF5C}Assistant\u{FF5C}></think>"
            ),
            "DSV4 final instruct tail must be closed-thinking. Decoded: \(multiTurnDecoded)"
        )
    }
}
