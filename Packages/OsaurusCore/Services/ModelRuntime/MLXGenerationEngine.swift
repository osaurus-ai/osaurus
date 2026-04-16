//
//  MLXGenerationEngine.swift
//  osaurus
//
//  Encapsulates MLX message preparation and generation stream construction.
//  Cache management is delegated to vmlx-swift-lm's CacheCoordinator via
//  the TokenIterator's cacheCoordinator parameter.
//

import CoreImage
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import MLXVLM  // MediaProcessing for image downscaling
import os.log

private let engineLog = Logger(subsystem: "ai.osaurus", category: "Generation")
private let engineSignposter = OSSignposter(subsystem: "ai.osaurus", category: "Generation")

struct MLXGenerationEngine {

    private static let maxImageSize = CGSize(width: 1024, height: 1024)

    private static func downscaleIfNeeded(_ image: CIImage) -> CIImage {
        let scale = min(MediaProcessing.bestFitScale(image.extent.size, in: maxImageSize), 1.0)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    static func preprocessImages(in chat: [MLXLMCommon.Chat.Message]) -> [MLXLMCommon.Chat.Message] {
        chat.map { message in
            let processedImages = message.images.map { userInputImage -> UserInput.Image in
                switch userInputImage {
                case .ciImage(let ciImage):
                    return .ciImage(downscaleIfNeeded(ciImage))
                default:
                    return userInputImage
                }
            }
            return MLXLMCommon.Chat.Message(
                role: message.role,
                content: message.content,
                images: processedImages,
                videos: message.videos
            )
        }
    }

    static func prepareAndGenerate(
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        generation: GenerationParameters,
        runtime: RuntimeConfig,
        wiredMemoryTicket: WiredMemoryTicket?
    ) async throws -> (
        stream: AsyncStream<MLXLMCommon.TokenGeneration>,
        tokenizer: any Tokenizer,
        promptTokens: [Int],
        genTask: Task<Void, Never>,
        toolCallFormat: ToolCallFormat
    ) {
        let spState = engineSignposter.beginInterval("prepareAndGenerate", id: engineSignposter.makeSignpostID())
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { engineSignposter.endInterval("prepareAndGenerate", spState) }

        // Named result box for crossing the actor boundary.
        final class ResultBox: @unchecked Sendable {
            let stream: AsyncStream<MLXLMCommon.TokenGeneration>
            let tokenizer: any Tokenizer
            let promptTokens: [Int]
            let genTask: Task<Void, Never>
            let toolCallFormat: ToolCallFormat
            init(
                _ stream: AsyncStream<MLXLMCommon.TokenGeneration>,
                _ tokenizer: any Tokenizer,
                _ promptTokens: [Int],
                _ genTask: Task<Void, Never>,
                _ toolCallFormat: ToolCallFormat
            ) {
                self.stream = stream; self.tokenizer = tokenizer
                self.promptTokens = promptTokens; self.genTask = genTask
                self.toolCallFormat = toolCallFormat
            }
        }

        let trace = generation.ttftTrace
        let result: ResultBox = try await container.perform { (context: MLXLMCommon.ModelContext) in
            trace?.mark("container_perform_entered")
            let chat = preprocessImages(in: buildChat())
            let toolsSpec = buildToolsSpec()
            let parameters = ModelRuntime.makeGenerateParameters(
                temperature: generation.temperature ?? 0.7,
                maxTokens: generation.maxTokens,
                topP: generation.topPOverride ?? runtime.topP,
                repetitionPenalty: generation.repetitionPenalty,
                maxKV: runtime.maxKV
            )
            // When the caller has an opinion on thinking (toggle is present), forward
            // it explicitly as `enable_thinking: true/false` — models whose templates
            // default the kwarg OFF when it's absent would otherwise silently stay
            // off even with the UI toggle enabled.
            let additionalContext: [String: any Sendable]?
            if let disableThinking = generation.modelOptions["disableThinking"]?.boolValue {
                additionalContext = ["enable_thinking": !disableThinking]
            } else {
                additionalContext = nil
            }
            let fullInput = MLXLMCommon.UserInput(
                chat: chat,
                processing: .init(),
                tools: toolsSpec,
                additionalContext: additionalContext
            )
            let fullLMInput: LMInput
            trace?.mark("tokenization_start")
            do {
                fullLMInput = try await context.processor.prepare(input: fullInput)
            } catch {
                let detail =
                    (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                throw NSError(
                    domain: "MLXGenerationEngine",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Chat template error: \(detail)"]
                )
            }
            trace?.mark("tokenization_done")

            var contextWithEOS = context
            let existing = context.configuration.extraEOSTokens
            let extra: Set<String> = Set(["</end_of_turn>", "<end_of_turn>", "<|end|>", "<eot>"])
            contextWithEOS.configuration.extraEOSTokens = existing.union(extra)

            let newPromptTokens = fullLMInput.text.tokens.asArray(Int.self)
            engineLog.info(
                "prepareAndGenerate: promptTokens=\(newPromptTokens.count, privacy: .public) hasImage=\(fullLMInput.image != nil, privacy: .public)"
            )
            guard !newPromptTokens.isEmpty else {
                throw NSError(
                    domain: "MLXGenerationEngine",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Tokenizer produced no tokens for the given input"]
                )
            }

            // Create TokenIterator with cacheCoordinator — the package handles
            // prefix fetch, KV restore, partial prefill, and post-gen cache store.
            let coordinator = container.cacheCoordinator
            let iterator = try TokenIterator(
                input: fullLMInput,
                model: contextWithEOS.model,
                parameters: parameters,
                cacheCoordinator: coordinator
            )

            engineLog.info(
                "prepareAndGenerate: constructing stream promptTokens=\(newPromptTokens.count, privacy: .public) cacheCoordinator=\(coordinator != nil, privacy: .public)"
            )
            engineSignposter.emitEvent(
                "prefillComplete",
                id: engineSignposter.makeSignpostID(),
                "promptTokens: \(newPromptTokens.count, privacy: .public)"
            )
            let (stream, genTask) = MLXLMCommon.generateTokenTask(
                promptTokenCount: newPromptTokens.count,
                modelConfiguration: contextWithEOS.configuration,
                tokenizer: contextWithEOS.tokenizer,
                iterator: iterator,
                wiredMemoryTicket: wiredMemoryTicket
            )
            engineLog.info("prepareAndGenerate: generateTokenTask created, returning stream")

            let toolCallFormat = contextWithEOS.configuration.toolCallFormat ?? .json
            return ResultBox(
                stream,
                contextWithEOS.tokenizer,
                newPromptTokens,
                genTask,
                toolCallFormat
            )
        }
        let durationMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        engineLog.info(
            "[perf] prepareAndGenerate durationMs=\(Int(durationMs), privacy: .public) promptTokens=\(result.promptTokens.count, privacy: .public)"
        )
        return (
            result.stream, result.tokenizer, result.promptTokens, result.genTask,
            result.toolCallFormat
        )
    }
}
