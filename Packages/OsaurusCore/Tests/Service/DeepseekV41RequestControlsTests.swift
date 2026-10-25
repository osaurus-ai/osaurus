//
//  DeepseekV41RequestControlsTests.swift
//  osaurusTests
//
//  DeepSeek-V4.1 request controls: the vLLM-style `chat_template_kwargs`
//  thinking switch, explicit thinking-off precedence, and the prefix-cache
//  restore count that becomes `usage.prompt_tokens_details.cached_tokens`.
//  DSV4-0731 keeps its existing request contract in every case.
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("DeepSeek-V4.1 request controls")
struct DeepseekV41RequestControlsTests {
    private static let v41Model = "DeepSeek-V4.1-Flash-1017-JANG-Q2Q3-IMATRIX"
    private static let v0731Model = "DeepSeek-V4-Flash-0731-JANG"

    private static func decode(_ json: String) throws -> ChatCompletionRequest {
        try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
    }

    @Test func v41FamilyMatcherExcludes0731() {
        #expect(ModelFamilyNames.isDSV41Family(Self.v41Model))
        #expect(ModelFamilyNames.isDSV41Family("jangq/dsv41-flash"))
        #expect(ModelFamilyNames.isDSV41Family("dsv4.1-flash"))
        #expect(!ModelFamilyNames.isDSV41Family(Self.v0731Model))
        #expect(!ModelFamilyNames.isDSV41Family("JANGQ/DeepSeek-V4-Flash-JANGTQ-K"))
        #expect(!ModelFamilyNames.isDSV41Family("DeepSeek-V3.1"))
    }

    @Test func v41HonorsChatTemplateKwargsThinkingSwitch() throws {
        let off = try Self.decode(
            """
            {"model":"\(Self.v41Model)","messages":[{"role":"user","content":"hi"}],
             "chat_template_kwargs":{"enable_thinking":false}}
            """)
        #expect(off.enable_thinking == false)

        let deepseekSpelling = try Self.decode(
            """
            {"model":"\(Self.v41Model)","messages":[{"role":"user","content":"hi"}],
             "chat_template_kwargs":{"thinking":false,"reasoning_effort":"xhigh"}}
            """)
        #expect(deepseekSpelling.enable_thinking == false)
        #expect(deepseekSpelling.reasoning_effort == "xhigh")

        // The top-level fields win when a client sends both.
        let both = try Self.decode(
            """
            {"model":"\(Self.v41Model)","messages":[{"role":"user","content":"hi"}],
             "enable_thinking":true,"reasoning_effort":"high",
             "chat_template_kwargs":{"enable_thinking":false,"reasoning_effort":"low"}}
            """)
        #expect(both.enable_thinking == true)
        #expect(both.reasoning_effort == "high")

        // Malformed kwargs never fail the request.
        let malformed = try Self.decode(
            """
            {"model":"\(Self.v41Model)","messages":[{"role":"user","content":"hi"}],
             "chat_template_kwargs":"enable_thinking=false"}
            """)
        #expect(malformed.enable_thinking == nil)
    }

    @Test func dsv4_0731RequestContractIsUnchanged() throws {
        let request = try Self.decode(
            """
            {"model":"\(Self.v0731Model)","messages":[{"role":"user","content":"hi"}],
             "chat_template_kwargs":{"enable_thinking":false,"reasoning_effort":"max"}}
            """)
        #expect(request.enable_thinking == nil)
        #expect(request.reasoning_effort == nil)
    }

    @Test func v41ExplicitThinkingOffBeatsAnEffort() {
        let generation = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(true), "reasoningEffort": .string("high")]
        )
        let v41 = MLXBatchAdapter.additionalContext(for: generation, modelName: Self.v41Model)
        #expect(v41["enable_thinking"] as? Bool == false)
        #expect(v41["reasoning_effort"] == nil)

        // 0731 keeps effort precedence exactly as before.
        let v0731 = MLXBatchAdapter.additionalContext(for: generation, modelName: Self.v0731Model)
        #expect(v0731["enable_thinking"] as? Bool == true)
        #expect(v0731["reasoning_effort"] as? String == "high")

        // Thinking-off without an effort is unchanged for both families.
        let offOnly = GenerationParameters(
            temperature: nil, maxTokens: 16, modelOptions: ["disableThinking": .bool(true)])
        #expect(
            MLXBatchAdapter.additionalContext(for: offOnly, modelName: Self.v41Model)["enable_thinking"]
                as? Bool == false)
        #expect(
            MLXBatchAdapter.additionalContext(for: offOnly, modelName: Self.v0731Model)["enable_thinking"]
                as? Bool == false)
    }

    /// Renders through the V4.1 bundle's own tokenizer (no weights are loaded).
    /// Skipped when the bundle is absent.
    @Test func v41TokenizerRendersChatRailWhenThinkingIsOff() async throws {
        let defaultPath = "/Users/eric/models/\(Self.v41Model)"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_DSV41_TEST_MODEL"] ?? defaultPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("tokenizer.json").path)
        else { return }

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: modelURL)
        let messages: [[String: any Sendable]] = [["role": "user", "content": "Say ok."]]

        let off = tokenizer.decode(
            tokenIds: try tokenizer.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: ["enable_thinking": false]),
            skipSpecialTokens: false)
        #expect(
            off.hasSuffix("<\u{FF5C}Assistant\u{FF5C}></think>"),
            "enable_thinking=false must render the V4.1 chat rail. Tail: \(off.suffix(80))")
        #expect(!off.contains("Reasoning Effort"), "The chat rail carries no effort line. \(off)")

        let on = tokenizer.decode(
            tokenIds: try tokenizer.applyChatTemplate(
                messages: messages, tools: nil,
                additionalContext: ["enable_thinking": true, "reasoning_effort": "high"]),
            skipSpecialTokens: false)
        #expect(on.hasSuffix("<\u{FF5C}Assistant\u{FF5C}><think>"), "Tail: \(on.suffix(80))")
        #expect(on.contains("Reasoning Effort: 75"), "V4.1 high is budget 75. \(on)")
    }

    /// V4.1 affine JANG takes the admitted generation allocator window (prefill
    /// scratch); 0731's fact is untouched. Skipped when the bundle is absent.
    @Test func v41BundleQualifiesForTheGenerationAllocatorWindow() {
        let url = URL(fileURLWithPath: "/Users/eric/models/\(Self.v41Model)")
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path)
        else { return }
        let facts = LoadBundleFacts.inspect(bundleURL: url)
        #expect(facts.isDeepseekV41AffineJANG)
        #expect(!facts.isPlainDeepseekV4AffineJANG)
        #expect(
            ModelRuntime.requiresAdmittedMLXAllocatorCeiling(
                isPlainDeepseekV4AffineJANG: facts.isPlainDeepseekV4AffineJANG
                    || facts.isDeepseekV41AffineJANG,
                usesNativeMTP: false))
    }

    @Test func cacheRestoreBecomesCachedInputTokenCount() async throws {
        let source = AsyncStream<Generation> { continuation in
            continuation.yield(.prefillProgress(PrefillProgress(
                stage: .cacheRestore, completedUnitCount: 6000, totalUnitCount: 6012,
                detail: "disk")))
            continuation.yield(.prefillProgress(PrefillProgress(
                stage: .prefill, completedUnitCount: 6000, totalUnitCount: 6012,
                detail: "running")))
            continuation.yield(.chunk("ok"))
            continuation.yield(.info(GenerateCompletionInfo(
                promptTokenCount: 6012, generationTokenCount: 2, promptTime: 0.4,
                generationTime: 0.1)))
            continuation.finish()
        }
        var cached: [Int] = []
        var sawCompletionAfterCached = false
        for try await event in GenerationEventMapper.map(
            events: source, promptTokenCount: 6012, suppressProgressUI: true)
        {
            switch event {
            case .cachedInputTokenCount(let count): cached.append(count)
            case .completionInfo: sawCompletionAfterCached = !cached.isEmpty
            default: break
            }
        }
        #expect(cached == [6000])
        #expect(sawCompletionAfterCached)

        // A cold request reports nothing (the usage field stays omitted).
        let cold = AsyncStream<Generation> { continuation in
            continuation.yield(.chunk("ok"))
            continuation.yield(.info(GenerateCompletionInfo(
                promptTokenCount: 12, generationTokenCount: 2, promptTime: 0.1,
                generationTime: 0.1)))
            continuation.finish()
        }
        var coldCached = 0
        for try await event in GenerationEventMapper.map(
            events: cold, promptTokenCount: 12, suppressProgressUI: true)
        {
            if case .cachedInputTokenCount = event { coldCached += 1 }
        }
        #expect(coldCached == 0)
    }

    @Test func cachedTokensReachTheUsageBlock() throws {
        let hint = StreamingStatsHint.encode(
            tokenCount: 2, tokensPerSecond: 20, cachedInputTokenCount: 6000)
        let decoded = try #require(StreamingStatsHint.decode(hint))
        #expect(decoded.cachedInputTokenCount == 6000)

        let usage = Usage(
            prompt_tokens: 6012, completion_tokens: 2, total_tokens: 6014,
            prompt_tokens_details: Usage.cachedPromptDetails(
                decoded.cachedInputTokenCount, promptTokens: 6012))
        let json = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
        #expect(json.contains(#""cached_tokens":6000"#), "\(json)")

        #expect(Usage.cachedPromptDetails(nil, promptTokens: 10) == nil)
        #expect(Usage.cachedPromptDetails(0, promptTokens: 10) == nil)
        #expect(Usage.cachedPromptDetails(50, promptTokens: 10)?.cached_tokens == 10)
    }
}
