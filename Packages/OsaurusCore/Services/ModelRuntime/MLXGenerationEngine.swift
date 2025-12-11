//
//  MLXGenerationEngine.swift
//  osaurus
//
//  Encapsulates MLX message preparation and generation stream construction.
//

import Foundation
import MLXLLM
import MLXLMCommon

struct MLXGenerationEngine {
    static func prepareAndGenerate(
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: Any]]?,
        generation: GenerationParameters,
        runtime: RuntimeConfig
    ) async throws -> AsyncStream<MLXLMCommon.Generation> {
        let stream: AsyncStream<MLXLMCommon.Generation> = try await container.perform {
            (context: MLXLMCommon.ModelContext) in
            let chat = buildChat()
            let toolsSpec = buildToolsSpec()
            let parameters = ModelRuntime.makeGenerateParameters(
                temperature: generation.temperature ?? 0.7,
                maxTokens: generation.maxTokens,
                topP: generation.topPOverride ?? runtime.topP,
                repetitionPenalty: generation.repetitionPenalty,
                kvBits: runtime.kvBits,
                kvGroup: runtime.kvGroup,
                quantStart: runtime.quantStart,
                maxKV: runtime.maxKV,
                prefillStep: runtime.prefillStep
            )
            let fullInput = MLXLMCommon.UserInput(chat: chat, processing: .init(), tools: toolsSpec)
            let fullLMInput = try await context.processor.prepare(input: fullInput)

            var contextWithEOS = context
            let existing = context.configuration.extraEOSTokens
            let extra: Set<String> = Set(["</end_of_turn>", "<end_of_turn>", "<|end|>", "<eot>"])
            contextWithEOS.configuration.extraEOSTokens = existing.union(extra)

            return try MLXLMCommon.generate(
                input: fullLMInput,
                cache: nil,
                parameters: parameters,
                context: contextWithEOS
            )
        }
        return stream
    }
}
